package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const version = "1.1.1"

const cloudflareRanges = `
173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32`

var blockedRanges = []netip.Prefix{
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("2001:db8::/32"),
}

type result struct {
	SNI         string   `json:"sni"`
	Target      string   `json:"target"`
	Score       int      `json:"score"`
	Eligible    bool     `json:"eligible"`
	Reasons     []string `json:"reasons"`
	Detail      string   `json:"detail,omitempty"`
	Reachable   bool     `json:"reachable"`
	Cloudflare  bool     `json:"cloudflare"`
	CertValid   bool     `json:"cert_valid"`
	TLSVersion  string   `json:"tls_version"`
	ALPN        string   `json:"alpn"`
	KEX         string   `json:"kex"`
	TLSMs       int64    `json:"tls_ms"`
	PingMs      int      `json:"ping_ms"`
	CertBytes   int      `json:"cert_size_bytes"`
	CertCount   int      `json:"cert_chain_len"`
	KeyType     string   `json:"key_type"`
	Issuer      string   `json:"issuer"`
	DNSMs       int64    `json:"dns_ms"`
	ResolvedIPs []string `json:"resolved_ips"`
	IP          string   `json:"ip,omitempty"`
	ServerNames []string `json:"server_names,omitempty"`
}

type report struct {
	Tool       string    `json:"tool"`
	Version    string    `json:"version"`
	Timestamp  time.Time `json:"timestamp"`
	BestSNI    string    `json:"best_sni"`
	BestTarget string    `json:"best_target"`
	PoolSize   int       `json:"pool_size"`
	SampleSize int       `json:"sample_size"`
	Results    []result  `json:"results"`
}

func normalizeHost(host string) string {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if ip, err := netip.ParseAddr(host); err == nil && ip.Zone() == "" {
		return ip.Unmap().String()
	}
	if len(host) > 253 {
		return ""
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return ""
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return ""
			}
		}
	}
	return host
}

func parseTarget(input string) (string, string) {
	host, port := input, "443"
	if h, p, err := net.SplitHostPort(input); err == nil {
		host, port = h, p
	} else if strings.HasPrefix(input, "[") && strings.HasSuffix(input, "]") {
		host = input[1 : len(input)-1]
	}
	host = normalizeHost(host)
	number, err := strconv.Atoi(port)
	if host == "" || err != nil || number < 1 || number > 65535 {
		return "", ""
	}
	return host, strconv.Itoa(number)
}

func containsIP(ranges []netip.Prefix, ip netip.Addr) bool {
	return slices.ContainsFunc(ranges, func(prefix netip.Prefix) bool { return prefix.Contains(ip) })
}

func loadCloudflareRanges() []netip.Prefix {
	var ranges []netip.Prefix
	for _, raw := range strings.Fields(cloudflareRanges) {
		ranges = append(ranges, netip.MustParsePrefix(raw))
	}

	// Fetch both families in one request. Keep the bundled list on failure.
	client := http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get("https://api.cloudflare.com/client/v4/ips")
	if err != nil {
		return ranges
	}
	defer resp.Body.Close()
	var payload struct {
		Success bool
		Result  struct {
			IPv4 []string `json:"ipv4_cidrs"`
			IPv6 []string `json:"ipv6_cidrs"`
		}
	}
	if resp.StatusCode != http.StatusOK ||
		json.NewDecoder(io.LimitReader(resp.Body, 65536)).Decode(&payload) != nil ||
		!payload.Success || len(payload.Result.IPv4) == 0 || len(payload.Result.IPv6) == 0 {
		return ranges
	}
	var fresh []netip.Prefix
	for _, raw := range append(payload.Result.IPv4, payload.Result.IPv6...) {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil || prefix.Bits() == 0 {
			return ranges
		}
		fresh = append(fresh, prefix)
	}
	return fresh
}

func writeProxyHeader(conn net.Conn, xver int) error {
	local := conn.LocalAddr().(*net.TCPAddr).AddrPort()
	remote := conn.RemoteAddr().(*net.TCPAddr).AddrPort()
	src, dst := local.Addr().Unmap(), remote.Addr().Unmap()
	if xver == 1 {
		family := "TCP6"
		if src.Is4() {
			family = "TCP4"
		}
		_, err := fmt.Fprintf(conn, "PROXY %s %s %s %d %d\r\n", family, src, dst, local.Port(), remote.Port())
		return err
	}
	header := []byte("\r\n\r\n\x00\r\nQUIT\n\x21")
	if src.Is4() {
		header = append(header, 0x11, 0, 12)
	} else {
		header = append(header, 0x21, 0, 36)
	}
	header = append(header, src.AsSlice()...)
	header = append(header, dst.AsSlice()...)
	header = binary.BigEndian.AppendUint16(header, local.Port())
	header = binary.BigEndian.AppendUint16(header, remote.Port())
	_, err := conn.Write(header)
	return err
}

func (r *result) reject(reason string, err error) result {
	r.Reasons = append(r.Reasons, reason)
	if err != nil {
		r.Detail = err.Error()
	}
	return *r
}

func (r *result) checkTLS(state tls.ConnectionState) {
	r.Reachable = true
	r.TLSVersion = strings.Replace(tls.VersionName(state.Version), "TLS ", "TLSv", 1)
	r.ALPN = state.NegotiatedProtocol
	switch r.ALPN {
	case "http/1.1":
		r.ALPN = "http1.1"
	case "":
		r.ALPN = "none"
	}
	r.KEX = state.CurveID.String()
	switch state.CurveID {
	case tls.X25519MLKEM768:
		r.KEX = "MLKEM768"
	case tls.X25519:
		r.KEX = "X25519"
	}
	if state.Version != tls.VersionTLS13 {
		r.reject("tls_below_1_3", nil)
	}
	if r.ALPN != "h2" {
		r.reject("no_h2", nil)
	}
	if state.CurveID != tls.X25519 && state.CurveID != tls.X25519MLKEM768 {
		r.reject("no_x25519", nil)
	}

	r.CertCount = len(state.PeerCertificates)
	if r.CertCount == 0 {
		r.reject("no_certificate", nil)
		return
	}
	leaf := state.PeerCertificates[0]
	r.KeyType = leaf.PublicKeyAlgorithm.String()
	r.Issuer = leaf.Issuer.String()
	intermediates := x509.NewCertPool()
	for i, cert := range state.PeerCertificates {
		r.CertBytes += len(cert.Raw)
		if i > 0 {
			intermediates.AddCert(cert)
		}
	}
	for _, name := range leaf.DNSNames {
		if name != "" && !strings.HasPrefix(name, "*.") {
			r.ServerNames = append(r.ServerNames, name)
		}
	}
	_, err := leaf.Verify(x509.VerifyOptions{DNSName: r.SNI, Intermediates: intermediates})
	r.CertValid = err == nil
	if err != nil {
		r.reject("certificate_invalid", err)
	}
	r.Eligible = len(r.Reasons) == 0
}

func probe(input, sni string, timeout time.Duration, xver int, cfRanges []netip.Prefix) result {
	r := result{SNI: input, Target: input, Reasons: []string{}, ResolvedIPs: []string{}, TLSMs: -1, DNSMs: -1, PingMs: -1}
	host, port := parseTarget(input)
	if host == "" {
		return r.reject("invalid_target", nil)
	}
	if sni == "" {
		sni = host
	}
	r.SNI, r.Target = sni, net.JoinHostPort(host, port)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	start := time.Now()
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(ips) == 0 {
		return r.reject("dns_failed", err)
	}
	r.DNSMs = time.Since(start).Milliseconds()
	private := false
	for _, addr := range ips {
		ip := addr.Unmap()
		r.ResolvedIPs = append(r.ResolvedIPs, ip.String())
		r.Cloudflare = r.Cloudflare || containsIP(cfRanges, ip)
		private = private || !ip.IsGlobalUnicast() || ip.IsPrivate() || containsIP(blockedRanges, ip)
	}
	if r.Cloudflare {
		r.reject("cloudflare", nil)
	}
	if private {
		r.reject("non_public_ip", nil)
	}
	if len(r.Reasons) > 0 {
		return r
	}

	// Dial the vetted DNS snapshot. Try later addresses only on TCP failure.
	deadline, _ := ctx.Deadline()
	start = time.Now()
	var conn net.Conn
	for i, ip := range r.ResolvedIPs {
		budget := max(time.Until(deadline)/time.Duration(len(ips)-i), 300*time.Millisecond)
		dialer := net.Dialer{Timeout: budget}
		conn, err = dialer.DialContext(ctx, "tcp", net.JoinHostPort(ip, port))
		if err == nil {
			r.IP = ip
			break
		}
	}
	if err != nil {
		return r.reject("tcp_failed", err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(deadline); err != nil {
		return r.reject("tcp_failed", err)
	}
	if xver > 0 {
		if err := writeProxyHeader(conn, xver); err != nil {
			return r.reject("proxy_header_failed", err)
		}
	}
	tlsConn := tls.Client(conn, &tls.Config{
		ServerName:       sni,
		MinVersion:       tls.VersionTLS12,
		NextProtos:       []string{"h2", "http/1.1"},
		CurvePreferences: []tls.CurveID{tls.X25519, tls.X25519MLKEM768},
		// Verify after the handshake to report certificate and negotiation failures together.
		InsecureSkipVerify: true,
	})
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		return r.reject("tls_handshake_failed", err)
	}
	r.TLSMs = time.Since(start).Milliseconds()
	r.checkTLS(tlsConn.ConnectionState())
	return r
}

func scoreResults(rows []result, maxLatency int64) {
	fastestTLS, slowestTLS := maxLatency, int64(0)
	fastestDNS, slowestDNS := int64(1<<63-1), int64(0)
	smallestChain, largestChain := int64(1<<63-1), int64(0)
	for _, r := range rows {
		if !r.Eligible {
			continue
		}
		if r.TLSMs <= maxLatency {
			fastestTLS, slowestTLS = min(fastestTLS, r.TLSMs), max(slowestTLS, r.TLSMs)
		}
		fastestDNS, slowestDNS = min(fastestDNS, r.DNSMs), max(slowestDNS, r.DNSMs)
		size := int64(r.CertBytes)
		smallestChain, largestChain = min(smallestChain, size), max(largestChain, size)
	}
	points := func(value, low, high int64, weight int) int {
		return weight - int((value-low)*int64(weight)/max(high-low, 1))
	}
	for i := range rows {
		r := &rows[i]
		if !r.Eligible {
			continue
		}
		r.Score = 25 + 12 + 8 + 7
		if r.KEX == "MLKEM768" {
			r.Score += 3
		}
		if r.TLSMs <= maxLatency {
			r.Score += points(r.TLSMs, fastestTLS, slowestTLS, 20)
		}
		r.Score += points(r.DNSMs, fastestDNS, slowestDNS, 5)
		r.Score += points(int64(r.CertBytes), smallestChain, largestChain, 10)
		switch r.KeyType {
		case "ECDSA":
			r.Score += 10
		case "RSA":
			r.Score += 6
		default:
			r.Score += 2
		}
	}
	slices.SortStableFunc(rows, func(a, b result) int { return b.Score - a.Score })
}

func readTargets(file string, args []string) ([]string, error) {
	if len(args) == 0 {
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		args = strings.Split(string(data), "\n")
	}
	var targets []string
	seen := make(map[string]bool)
	for _, input := range args {
		input = strings.TrimSpace(strings.SplitN(strings.TrimPrefix(input, "\ufeff"), "#", 2)[0])
		key := strings.ToLower(input)
		if host, port := parseTarget(input); host != "" {
			key = net.JoinHostPort(host, port)
		}
		if input != "" && !seen[key] {
			seen[key] = true
			targets = append(targets, input)
		}
	}
	if len(targets) == 0 {
		return nil, fmt.Errorf("no targets")
	}
	return targets, nil
}

func scanTargets(targets []string, jobs int, sni string, timeout time.Duration, xver int, cf []netip.Prefix, verbose bool) []result {
	rows := make([]result, len(targets))
	queue := make(chan int)
	var wg sync.WaitGroup
	for range min(jobs, len(targets)) {
		wg.Go(func() {
			for i := range queue {
				r := probe(targets[i], sni, timeout, xver, cf)
				rows[i] = r
				if verbose {
					status := strings.Join(r.Reasons, ", ")
					if r.Eligible {
						status = fmt.Sprintf("eligible (%s, %s)", r.TLSVersion, r.KEX)
					}
					fmt.Fprintf(os.Stderr, "[%d/%d] %s %s\n", i+1, len(targets), r.Target, status)
				}
			}
		})
	}
	for i := range targets {
		queue <- i
	}
	close(queue)
	wg.Wait()
	return rows
}

func parseArgs(args []string) ([]string, error) {
	var options, targets []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			targets = append(targets, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			targets = append(targets, arg)
			continue
		}
		options = append(options, arg)
		name, _, assigned := strings.Cut(strings.TrimLeft(arg, "-"), "=")
		option := flag.Lookup(name)
		if option == nil || assigned {
			continue
		}
		if boolean, ok := option.Value.(interface{ IsBoolFlag() bool }); ok && boolean.IsBoolFlag() {
			continue
		}
		if i+1 == len(args) {
			return nil, fmt.Errorf("flag %s requires a value", arg)
		}
		i++
		options = append(options, args[i])
	}
	return targets, flag.CommandLine.Parse(options)
}

func run() error {
	defaultPool := os.Getenv("SNI_FINDER_POOL")
	if defaultPool == "" {
		defaultPool = "domains.txt"
	}
	pool := flag.String("l", defaultPool, "domain pool file")
	count := flag.Int("n", 15, "random sample size")
	timeout := flag.Int("t", 10, "total timeout per target in seconds")
	output := flag.String("o", "", "write JSON to a file (default: stdout)")
	autoApply := flag.Bool("y", false, "apply the best eligible target to Xray")
	verbose := flag.Bool("v", false, "show per-target progress on stderr")
	showVersion := flag.Bool("V", false, "show version")
	noMenu := flag.Bool("no-menu", false, "skip the interactive menu")
	config := flag.String("xray-config", "", "Xray configuration path")
	maxLatency := flag.Int64("max-latency", 300, "maximum TCP + TLS latency for scoring in ms")
	all := flag.Bool("all", false, "audit the entire pool")
	jobs := flag.Int("j", 24, "number of concurrent probes")
	sni := flag.String("sni", "", "override SNI for one explicit target")
	xver := flag.Int("xver", 0, "PROXY protocol version (0, 1 or 2)")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: sni-finder.sh [options] [host[:port] ...]")
		flag.PrintDefaults()
	}
	args, err := parseArgs(os.Args[1:])
	if err != nil {
		return err
	}
	if *showVersion {
		fmt.Printf("sni-finder.sh v%s\n", version)
		return nil
	}
	if *count < 1 || *timeout < 1 || *timeout > 3600 || *jobs < 1 || *maxLatency < 0 || *xver < 0 || *xver > 2 {
		return fmt.Errorf("invalid count, timeout, concurrency, latency or xver")
	}
	if *sni != "" {
		*sni = normalizeHost(strings.TrimSpace(*sni))
		if *sni == "" || len(args) != 1 {
			return fmt.Errorf("--sni requires a valid hostname and one explicit target")
		}
	}
	targets, err := readTargets(*pool, args)
	if err != nil {
		return err
	}
	cf := loadCloudflareRanges()
	input := bufio.NewScanner(os.Stdin)
	terminal, _ := os.Stdin.Stat()

	for {
		selected := targets
		if len(args) == 0 && !*all && *count < len(targets) {
			selected = slices.Clone(targets)
			rand.Shuffle(len(selected), func(i, j int) { selected[i], selected[j] = selected[j], selected[i] })
			selected = selected[:*count]
		}
		rows := scanTargets(selected, *jobs, *sni, time.Duration(*timeout)*time.Second, *xver, cf, *verbose)
		scoreResults(rows, *maxLatency)
		data := report{Tool: "sni-finder.sh", Version: version, Timestamp: time.Now().UTC(),
			PoolSize: len(targets), SampleSize: len(rows), Results: rows}
		best := rows[0]
		if best.Eligible {
			data.BestSNI, data.BestTarget = best.SNI, best.Target
		}
		encoded, err := json.MarshalIndent(data, "", "  ")
		if err != nil {
			return err
		}
		encoded = append(encoded, '\n')
		if *output == "" {
			_, err = os.Stdout.Write(encoded)
		} else {
			err = os.WriteFile(*output, encoded, 0644)
		}
		if err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "%d/%d eligible\n", countEligible(rows), len(rows))
		if best.Eligible {
			fmt.Fprintf(os.Stderr, "Best target %s, SNI %s (score %d)\n", best.Target, best.SNI, best.Score)
		}
		if *autoApply {
			return applyTarget(best, *config, *xver)
		}
		if *noMenu || terminal == nil || terminal.Mode()&os.ModeCharDevice == 0 {
			return nil
		}
		retest, err := menu(input, rows, *config, *xver)
		if !retest || err != nil {
			return err
		}
	}
}

func countEligible(rows []result) int {
	count := 0
	for _, r := range rows {
		if r.Eligible {
			count++
		}
	}
	return count
}

func menu(input *bufio.Scanner, rows []result, path string, xver int) (bool, error) {
	for {
		fmt.Fprintln(os.Stderr, "0) Exit\n1) Re-test\n2) Apply best eligible target and restart\n3) Browse eligible targets by country")
		fmt.Fprint(os.Stderr, "Choose [0-3]: ")
		if !input.Scan() {
			return false, input.Err()
		}
		switch strings.TrimSpace(input.Text()) {
		case "0":
			return false, nil
		case "1":
			return true, nil
		case "2":
			if rows[0].Eligible {
				return false, applyTarget(rows[0], path, xver)
			}
			fmt.Fprintln(os.Stderr, "No eligible target to apply")
		case "3":
			browseCountries(input, rows)
		default:
			fmt.Fprintln(os.Stderr, "Invalid choice")
		}
	}
}

func browseCountries(input *bufio.Scanner, rows []result) {
	eligible := countEligible(rows)
	if eligible == 0 {
		fmt.Fprintln(os.Stderr, "No eligible targets to browse")
		return
	}
	fmt.Fprintf(os.Stderr, "Number of top targets to look up (default: %d)\n", eligible)
	fmt.Fprint(os.Stderr, "Press Enter for the default or enter a number: ")
	if !input.Scan() {
		return
	}
	count, err := strconv.Atoi(strings.TrimSpace(input.Text()))
	if err != nil || count < 1 || count > eligible {
		count = eligible
	}
	client := http.Client{Timeout: 4 * time.Second}
	countries := make(map[string][]result)
	ipCountries := make(map[string]string)
	for _, r := range rows[:count] {
		country, found := ipCountries[r.IP]
		if !found {
			country = "UNKNOWN"
			resp, err := client.Get("https://ip.im/" + r.IP)
			if err == nil {
				scanner := bufio.NewScanner(io.LimitReader(resp.Body, 65536))
				for resp.StatusCode == http.StatusOK && scanner.Scan() {
					if value, ok := strings.CutPrefix(strings.ToLower(scanner.Text()), "country:"); ok {
						country = strings.ToUpper(strings.TrimSpace(value))
						break
					}
				}
				resp.Body.Close()
			}
			ipCountries[r.IP] = country
		}
		countries[country] = append(countries[country], r)
	}
	var names []string
	for country := range countries {
		names = append(names, country)
	}
	slices.Sort(names)
	for _, country := range names {
		fmt.Fprintf(os.Stderr, "%s (%d)\n", country, len(countries[country]))
		for _, r := range countries[country] {
			fmt.Fprintf(os.Stderr, "  %s (%s) score %d\n", r.Target, r.IP, r.Score)
		}
	}
}

func applyTarget(best result, path string, xver int) error {
	if !best.Eligible {
		return fmt.Errorf("no eligible target to apply")
	}
	if path == "" {
		for _, candidate := range []string{"/usr/local/etc/xray/config.json", "/etc/xray/config.json",
			"/opt/xray/config.json", "/usr/local/etc/v2ray/config.json", "/etc/v2ray/config.json"} {
			if stat, err := os.Stat(candidate); err == nil && stat.Mode().IsRegular() {
				path = candidate
				break
			}
		}
	}
	if path == "" {
		return fmt.Errorf("Xray configuration not found; specify --xray-config")
	}
	path, err := filepath.EvalSymlinks(path)
	if err != nil {
		return err
	}
	stat, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !stat.Mode().IsRegular() {
		return fmt.Errorf("configuration is not a regular file")
	}
	original, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var config map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(original)))
	decoder.UseNumber()
	if !json.Valid(original) {
		return fmt.Errorf("configuration must be valid JSON")
	}
	if err := decoder.Decode(&config); err != nil {
		return err
	}
	inbounds, _ := config["inbounds"].([]any)
	updated := 0
	for _, raw := range inbounds {
		inbound, _ := raw.(map[string]any)
		stream, _ := inbound["streamSettings"].(map[string]any)
		settings, _ := stream["realitySettings"].(map[string]any)
		if settings == nil || (stream["security"] != nil && stream["security"] != "reality") {
			continue
		}
		value, exists := settings["xver"]
		if exists && value != json.Number(strconv.Itoa(xver)) || !exists && xver != 0 {
			return fmt.Errorf("configuration xver differs from the tested --xver %d", xver)
		}
		settings["serverNames"] = []string{best.SNI}
		if _, exists := settings["serverName"]; exists {
			settings["serverName"] = best.SNI
		}
		_, hasDest := settings["dest"]
		if _, hasTarget := settings["target"]; hasTarget || !hasDest {
			settings["target"] = best.Target
		}
		if hasDest {
			settings["dest"] = best.Target
		}
		if xhttp, ok := stream["xhttpSettings"].(map[string]any); ok && xhttp["host"] != nil {
			xhttp["host"] = best.SNI
		}
		updated++
	}
	if updated == 0 {
		return fmt.Errorf("no REALITY inbounds in %s", path)
	}
	content, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".sni-config-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if err := temp.Chmod(stat.Mode().Perm()); err != nil {
		temp.Close()
		return err
	}
	_, err = temp.Write(append(content, '\n'))
	closeErr := temp.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	backup := path + ".bak." + strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := os.WriteFile(backup, original, stat.Mode().Perm()); err != nil {
		return err
	}
	if err := os.Rename(temp.Name(), path); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Updated %d REALITY inbound(s); backup %s\n", updated, backup)
	for _, svc := range []string{"xray", "v2ray"} {
		if exec.Command("systemctl", "is-active", "--quiet", svc).Run() == nil {
			if output, err := exec.Command("systemctl", "restart", svc).CombinedOutput(); err != nil {
				return fmt.Errorf("restart %s: %w: %s", svc, err, output)
			}
			break
		}
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

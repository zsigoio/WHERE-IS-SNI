package main

import (
	"crypto/tls"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestLegacyHandshakeIsIneligible(t *testing.T) {
	r := result{SNI: "example.org"}
	r.checkTLS(tls.ConnectionState{
		Version:            tls.VersionTLS12,
		NegotiatedProtocol: "http/1.1",
		CurveID:            tls.CurveP256,
	})
	want := []string{"tls_below_1_3", "no_h2", "no_x25519", "no_certificate"}
	if r.Eligible || !r.Reachable || r.TLSVersion != "TLSv1.2" || !slices.Equal(r.Reasons, want) {
		t.Fatalf("unexpected result: %+v", r)
	}
}

func TestRankingExcludesIneligibleTargets(t *testing.T) {
	rows := []result{
		{SNI: "legacy.example", Reachable: true, TLSVersion: "TLSv1.2", TLSMs: 1, CertBytes: 1},
		{SNI: "modern.example", Reachable: true, Eligible: true, TLSVersion: "TLSv1.3", TLSMs: 600, CertBytes: 2500, KeyType: "ECDSA", KEX: "X25519"},
	}
	scoreResults(rows, 300)
	if rows[0].SNI != "modern.example" || rows[0].Score != 77 || rows[1].Score != 0 {
		t.Fatalf("unexpected ranking: %+v", rows)
	}
}

func TestApplyWritesProbedTarget(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	path := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"inbounds":[
		{"streamSettings":{"security":"reality","realitySettings":{"dest":"old.example:8443","xver":1}}},
		{"streamSettings":{"security":"tls","xhttpSettings":{"host":"other.example"}}}
	]}`)
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	best := result{SNI: "new.example", Target: "203.0.113.10:443", Eligible: true}
	if err := applyTarget(best, path, 0); err == nil {
		t.Fatal("accepted a different xver")
	}
	if err := applyTarget(best, path, 1); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Inbounds []struct {
			Stream struct {
				Reality struct {
					Dest        string
					ServerNames []string
				} `json:"realitySettings"`
				XHTTP struct{ Host string } `json:"xhttpSettings"`
			} `json:"streamSettings"`
		}
	}
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	reality := config.Inbounds[0].Stream.Reality
	if reality.Dest != best.Target || !slices.Equal(reality.ServerNames, []string{best.SNI}) ||
		config.Inbounds[1].Stream.XHTTP.Host != "other.example" {
		t.Fatalf("unexpected config: %s", data)
	}
	backups, err := filepath.Glob(path + ".bak.*")
	if err != nil || len(backups) != 1 {
		t.Fatalf("unexpected backups: %v (%v)", backups, err)
	}
	if data, err := os.ReadFile(backups[0]); err != nil || !slices.Equal(data, original) {
		t.Fatalf("backup differs from original: %v", err)
	}
}

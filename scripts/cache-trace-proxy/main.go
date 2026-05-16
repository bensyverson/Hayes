// cache-trace-proxy is a diagnostic pass-through proxy for the Anthropic API.
//
// It forwards every request to https://api.anthropic.com untouched (including
// streaming responses), but tees each POST /v1/messages request body to disk so
// you can inspect exactly where `cache_control` breakpoints land across the
// successive requests of a multi-step tool-calling turn.
//
// Usage:
//
//	go run .            # listens on :8787
//	ANTHROPIC_BASE_URL=http://localhost:8787 claude
//
// Captures are written to ./captures/req-NNN.json (pretty-printed). A one-line
// summary of each request's cache_control placement is printed to stdout.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
)

const (
	listenAddr = ":8787"
	upstream   = "https://api.anthropic.com"
	captureDir = "captures"
)

var reqCounter atomic.Int64

func main() {
	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("bad upstream URL: %v", err)
	}
	if err := os.MkdirAll(captureDir, 0o755); err != nil {
		log.Fatalf("cannot create capture dir: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	orig := proxy.Director
	proxy.Director = func(r *http.Request) {
		// Tee the request body so we can both log it and forward it.
		if r.Body != nil && r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/v1/messages") {
			body, err := io.ReadAll(r.Body)
			if err == nil {
				r.Body = io.NopCloser(bytes.NewReader(body))
				r.ContentLength = int64(len(body))
				capture(body)
			}
		}
		orig(r)
		r.Host = target.Host
	}

	log.Printf("cache-trace-proxy listening on %s -> %s", listenAddr, upstream)
	log.Printf("run: ANTHROPIC_BASE_URL=http://localhost%s claude", listenAddr)
	log.Fatal(http.ListenAndServe(listenAddr, proxy))
}

// capture pretty-prints the request body to captures/req-NNN.json and prints a
// one-line summary of where cache_control breakpoints appear.
func capture(body []byte) {
	n := reqCounter.Add(1)
	path := filepath.Join(captureDir, fmt.Sprintf("req-%03d.json", n))

	var parsed any
	if err := json.Unmarshal(body, &parsed); err != nil {
		// Not JSON we understand — dump raw and move on.
		_ = os.WriteFile(path, body, 0o644)
		log.Printf("req-%03d: non-JSON body (%d bytes)", n, len(body))
		return
	}

	pretty, _ := json.MarshalIndent(parsed, "", "  ")
	if err := os.WriteFile(path, pretty, 0o644); err != nil {
		log.Printf("req-%03d: failed to write capture: %v", n, err)
	}

	msgCount, hits := analyze(parsed)
	if len(hits) == 0 {
		log.Printf("req-%03d: %d messages, NO cache_control", n, msgCount)
	} else {
		log.Printf("req-%03d: %d messages, cache_control at: %s", n, msgCount, strings.Join(hits, ", "))
	}
}

// analyze returns the message count and a list of human-readable locations
// where a cache_control key appears in the request body.
func analyze(parsed any) (msgCount int, hits []string) {
	root, ok := parsed.(map[string]any)
	if !ok {
		return 0, nil
	}

	if sys, ok := root["system"].([]any); ok {
		for i, blk := range sys {
			if hasCacheControl(blk) {
				hits = append(hits, fmt.Sprintf("system[%d]", i))
			}
		}
	}
	if tools, ok := root["tools"].([]any); ok {
		for i, t := range tools {
			if hasCacheControl(t) {
				hits = append(hits, fmt.Sprintf("tools[%d]", i))
			}
		}
	}

	msgs, _ := root["messages"].([]any)
	msgCount = len(msgs)
	for i, m := range msgs {
		mm, ok := m.(map[string]any)
		if !ok {
			continue
		}
		role, _ := mm["role"].(string)
		switch content := mm["content"].(type) {
		case []any:
			for j, blk := range content {
				if hasCacheControl(blk) {
					bt := blockType(blk)
					hits = append(hits, fmt.Sprintf("messages[%d:%s].content[%d:%s]", i, role, j, bt))
				}
			}
		default:
			if hasCacheControl(m) {
				hits = append(hits, fmt.Sprintf("messages[%d:%s]", i, role))
			}
		}
	}

	sort.Strings(hits)
	return msgCount, hits
}

func hasCacheControl(v any) bool {
	m, ok := v.(map[string]any)
	if !ok {
		return false
	}
	_, ok = m["cache_control"]
	return ok
}

func blockType(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return "?"
	}
	t, _ := m["type"].(string)
	if t == "" {
		return "?"
	}
	return t
}

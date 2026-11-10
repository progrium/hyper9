// The workloads' Go program: net/http over loopback, crypto/sha256, and
// encoding/json, each printing a deterministic result and its time.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

type Item struct {
	ID    int               `json:"id"`
	Name  string            `json:"name"`
	Score float64           `json:"score"`
	Tags  []string          `json:"tags"`
	Attrs map[string]string `json:"attrs"`
}

func timed(name string, f func() string) {
	t := time.Now()
	r := f()
	fmt.Printf("%s: %s\n", name, r)
	fmt.Fprintf(os.Stderr, "%s: %v\n", name, time.Since(t))
}

func main() {
	timed("sha256", func() string {
		buf := make([]byte, 1<<20)
		for i := range buf {
			buf[i] = byte(i * 31)
		}
		h := sha256.New()
		for i := 0; i < 64; i++ {
			h.Write(buf)
		}
		return fmt.Sprintf("%x", h.Sum(nil))
	})
	timed("json", func() string {
		items := make([]Item, 20000)
		for i := range items {
			items[i] = Item{ID: i, Name: fmt.Sprintf("item-%d", i), Score: float64(i) / 7, Tags: []string{"a", "b", fmt.Sprint(i % 13)}, Attrs: map[string]string{"k": fmt.Sprint(i * 3)}}
		}
		b, err := json.Marshal(items)
		if err != nil {
			return err.Error()
		}
		var back []Item
		if err := json.Unmarshal(b, &back); err != nil {
			return err.Error()
		}
		sum := 0.0
		for _, it := range back {
			sum += it.Score
		}
		return fmt.Sprintf("%d bytes, %d items, score sum %.4f, %x", len(b), len(back), sum, sha256.Sum256(b))
	})
	timed("http", func() string {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return "listen: " + err.Error()
		}
		mux := http.NewServeMux()
		mux.HandleFunc("/n/", func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, "hello %s", r.URL.Path[3:])
		})
		go http.Serve(ln, mux)
		total := 0
		for i := 0; i < 200; i++ {
			resp, err := http.Get(fmt.Sprintf("http://%s/n/%d", ln.Addr(), i))
			if err != nil {
				return "get: " + err.Error()
			}
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			total += len(b)
		}
		return fmt.Sprintf("200 requests, %d bytes", total)
	})
}

// Serves HTTP on loopback and fetches from it, in one process: Go's
// netpoller on epoll, with goroutines on several threads
// (design/linux-net.md, design/linux-threads.md).
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
)

func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Println("FAIL nethttp: listen:", err)
		os.Exit(1)
	}
	go http.Serve(ln, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello %s", r.URL.Path[1:])
	}))
	for i := 0; i < 3; i++ {
		resp, err := http.Get(fmt.Sprintf("http://%s/h9-%d", ln.Addr(), i))
		if err != nil {
			fmt.Println("FAIL nethttp: get:", err)
			os.Exit(1)
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if string(b) != fmt.Sprintf("hello h9-%d", i) {
			fmt.Printf("FAIL nethttp: body %q\n", b)
			os.Exit(1)
		}
	}
	fmt.Println("ok nethttp")
}

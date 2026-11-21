// Pure Go (CGO_ENABLED=0) host for libh9, Linux only: the library is
// embedded in the binary, loaded from a memfd with purego, and called over
// docs/embedding/capi.zig's C ABI. A proof of concept. To run it:
//
//	zig build capi -Dtarget=x86_64-linux-gnu && zig build
//	cp ../../../zig-out/lib/libh9.so ../../../zig-out/fixtures/hello-amd64 .
//	CGO_ENABLED=0 go build -o poc . && ./poc 4
package main

import (
	_ "embed"
	"fmt"
	"io"
	"os"
	"runtime"
	"sync"
	"time"

	"github.com/ebitengine/purego"
	"golang.org/x/sys/unix"
)

//go:embed libh9.so
var lib []byte

//go:embed hello-amd64
var hello []byte

func load() uintptr {
	fd, err := unix.MemfdCreate("libh9", unix.MFD_CLOEXEC)
	if err != nil {
		panic(err)
	}
	if _, err := unix.Write(fd, lib); err != nil {
		panic(err)
	}
	h, err := purego.Dlopen(fmt.Sprintf("/proc/self/fd/%d", fd), purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		panic(err)
	}
	return h
}

func main() {
	nw := 4
	if len(os.Args) > 1 {
		fmt.Sscan(os.Args[1], &nw)
	}
	h := load()
	var runAout func(prog *byte, n uintptr, outFd int, status *byte, cap uintptr) int32
	var backend func(status *byte, cap uintptr) int32
	purego.RegisterLibFunc(&runAout, h, "h9_run_aout")
	purego.RegisterLibFunc(&backend, h, "h9_backend")

	st := make([]byte, 256)
	backend(&st[0], uintptr(len(st)))
	fmt.Printf("backend: %s\n", cstr(st))

	// Keep the Go scheduler, GC, and async preemption (SIGURG) busy while
	// h9's threads run, to shake out signal and stack trouble.
	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
				_ = make([]byte, 1<<16)
				runtime.Gosched()
			}
		}
	}()

	var wg sync.WaitGroup
	for i := 0; i < nw; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 5; j++ {
				r, w, _ := os.Pipe()
				done := make(chan []byte)
				go func() { b, _ := io.ReadAll(r); done <- b }()
				st := make([]byte, 256)
				rc := runAout(&hello[0], uintptr(len(hello)), int(w.Fd()), &st[0], uintptr(len(st)))
				w.Close()
				out := <-done
				fmt.Printf("worker %d run %d: rc=%d status=%q out=%q\n", i, j, rc, cstr(st), out)
			}
		}(i)
	}
	wg.Wait()
	close(stop)
	runtime.GC()
	time.Sleep(100 * time.Millisecond)
	fmt.Println("ok")
}

func cstr(b []byte) string {
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

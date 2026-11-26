// The Go runtime and standard library behaviors the go-compat cases
// check, as a Linux program, one per mode in os.Args[1]
// (design/epoch-0/linux-threads.md):
//
//	hello      prints a greeting
//	sleep      8 goroutines sleep 100 ms; prints the elapsed ms
//	clock      prints time.Now in Unix ns, then the wall time across a 10 ms sleep
//	numcpu     prints runtime.NumCPU and GOMAXPROCS
//	pid        prints Getpid and Getppid, then /proc/<pid>/status's Name and PPid
//	spin       CPU-bound goroutines, one per GOMAXPROCS; prints the most threads seen
//	exec       runs itself in "child" mode, which exits 7; prints its output and status
//	nilpanic   recovers from a nil dereference
//	signal     prints "ready", waits for os.Interrupt, and prints it
//	exit N     prints "exiting N" and exits with N
//	http URL   fetches URL and prints the status and body
//	timeofday  syscall.Gettimeofday 5 times 1 ms apart; prints the distinct usecs
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fail("usage: gocompat mode [arg]")
	}
	switch os.Args[1] {
	case "hello":
		fmt.Println("hello from go")
	case "sleep":
		start := time.Now()
		var wg sync.WaitGroup
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				time.Sleep(100 * time.Millisecond)
			}()
		}
		wg.Wait()
		fmt.Println(time.Since(start).Milliseconds())
	case "clock":
		a := time.Now()
		time.Sleep(10 * time.Millisecond)
		b := time.Now()
		fmt.Println(a.UnixNano())
		// Round(0) drops the monotonic reading, so this is wall time.
		fmt.Println(b.Round(0).Sub(a.Round(0)).Nanoseconds())
	case "numcpu":
		fmt.Println(runtime.NumCPU(), runtime.GOMAXPROCS(0))
	case "pid":
		pid := os.Getpid()
		fmt.Println(pid, os.Getppid())
		f, err := os.Open(fmt.Sprintf("/proc/%d/status", pid))
		if err != nil {
			fail("status:", err)
		}
		name, ppid := "", ""
		s := bufio.NewScanner(f)
		for s.Scan() {
			if v, ok := strings.CutPrefix(s.Text(), "Name:"); ok {
				name = strings.TrimSpace(v)
			} else if v, ok := strings.CutPrefix(s.Text(), "PPid:"); ok {
				ppid = strings.TrimSpace(v)
			}
		}
		fmt.Println(name, ppid)
	case "spin":
		spin()
	case "exec":
		cmd := exec.Command("/proc/self/exe", "child")
		out, err := cmd.Output()
		fmt.Print(string(out))
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			fail("err:", err)
		}
		fmt.Println("status", ee.ExitCode())
	case "child":
		fmt.Println("child ok")
		os.Exit(7)
	case "nilpanic":
		defer func() {
			fmt.Println("recovered:", recover())
		}()
		fmt.Println(deref(nil))
	case "signal":
		c := make(chan os.Signal, 1)
		signal.Notify(c, os.Interrupt)
		fmt.Println("ready")
		select {
		case s := <-c:
			fmt.Println("got", s)
		case <-time.After(20 * time.Second):
			fail("timeout")
		}
	case "exit":
		n, _ := strconv.Atoi(arg())
		fmt.Println("exiting", n)
		os.Exit(n)
	case "http":
		resp, err := http.Get(arg())
		if err != nil {
			fail("err:", err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			fail("read:", err)
		}
		fmt.Println(resp.StatusCode)
		fmt.Print(string(body))
	case "timeofday":
		var tv syscall.Timeval
		distinct := map[int64]bool{}
		for i := 0; i < 5; i++ {
			if err := syscall.Gettimeofday(&tv); err != nil {
				fail("err:", err)
			}
			distinct[int64(tv.Usec)] = true
			time.Sleep(time.Millisecond)
		}
		fmt.Println(len(distinct))
	default:
		fail("unknown mode", os.Args[1])
	}
}

func arg() string {
	if len(os.Args) < 3 {
		fail(os.Args[1] + ": missing argument")
	}
	return os.Args[2]
}

func fail(a ...any) {
	fmt.Println(a...)
	os.Exit(1)
}

type T struct{ x int }

//go:noinline
func deref(p *T) int { return p.x }

var sink atomic.Uint64

// spin runs a CPU-bound goroutine per GOMAXPROCS and, while they run,
// counts this process's threads in /proc/self/task.
func spin() {
	n := runtime.GOMAXPROCS(0)
	var stop atomic.Bool
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			x := uint64(1)
			for !stop.Load() {
				x = x*6364136223846793005 + 1442695040888963407
			}
			sink.Add(x)
		}()
	}
	most := 0
	for i := 0; i < 20; i++ {
		time.Sleep(20 * time.Millisecond)
		ents, err := os.ReadDir("/proc/self/task")
		if err != nil {
			fail("task:", err)
		}
		most = max(most, len(ents))
	}
	stop.Store(true)
	wg.Wait()
	fmt.Println(most)
}

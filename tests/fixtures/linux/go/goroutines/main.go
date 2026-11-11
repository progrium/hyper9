// Starts goroutines that each sleep 100 ms, waits for them, and prints
// "ok goroutines" with the threads the runtime made
// (design/linux-threads.md).
package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"
)

func main() {
	start := time.Now()
	var wg sync.WaitGroup
	var mu sync.Mutex
	sum := 0
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			time.Sleep(100 * time.Millisecond)
			mu.Lock()
			sum += i
			mu.Unlock()
		}(i)
	}
	wg.Wait()
	ms := time.Since(start).Milliseconds()
	if sum != 120 || ms < 100 {
		fmt.Println("FAIL goroutines:", sum, ms)
		os.Exit(1)
	}
	threads := "?"
	if b, err := os.ReadFile("/proc/self/status"); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, "Threads:") {
				threads = strings.TrimSpace(l[8:])
			}
		}
	}
	fmt.Println("ok goroutines", runtime.GOMAXPROCS(0), threads)
}

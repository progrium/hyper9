// Runs CPU-bound goroutines, one per GOMAXPROCS, and, while they spin,
// counts the threads in /proc/self/task. Prints the most it saw.
package main

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

var sink atomic.Uint64

func spin(stop *atomic.Bool) {
	x := uint64(1)
	for !stop.Load() {
		x = x*6364136223846793005 + 1442695040888963407
	}
	sink.Add(x)
}

func main() {
	n := runtime.GOMAXPROCS(0)
	var stop atomic.Bool
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			spin(&stop)
		}()
	}
	most := 0
	for i := 0; i < 20; i++ {
		time.Sleep(20 * time.Millisecond)
		ents, err := os.ReadDir("/proc/self/task")
		if err != nil {
			fmt.Println("task:", err)
			os.Exit(1)
		}
		most = max(most, len(ents))
	}
	stop.Store(true)
	wg.Wait()
	fmt.Println(most)
}

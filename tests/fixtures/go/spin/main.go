// Runs CPU-bound goroutines, one per GOMAXPROCS, and, while they spin,
// counts the processes in /proc. Prints the count.
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

// Go doesn't preempt goroutines by signals on Plan 9, and a small leaf
// function has no stack check to be preempted at, so the loop yields
// between rounds, as CPU-bound code on 9front has to.
func spin(stop *atomic.Bool) {
	x := uint64(1)
	for !stop.Load() {
		for i := 0; i < 100000; i++ {
			x = x*6364136223846793005 + 1442695040888963407
		}
		runtime.Gosched()
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
		ents, err := os.ReadDir("/proc")
		if err != nil {
			fmt.Println("proc:", err)
			os.Exit(1)
		}
		most = max(most, len(ents))
	}
	stop.Store(true)
	wg.Wait()
	fmt.Println(most)
}

// Runs the garbage collector while a goroutine spins in a loop with no
// calls, which only a signal (SIGURG, by tgkill) can preempt, and prints
// "ok gcloop" (design/linux-threads.md).
package main

import (
	"fmt"
	"runtime"
	"sync/atomic"
	"time"
)

var stop atomic.Bool
var sink uint64

func loop() {
	x := uint64(1)
	for !stop.Load() {
		x = x*6364136223846793005 + 1442695040888963407
	}
	sink = x
}

func main() {
	runtime.GOMAXPROCS(2)
	go loop()
	time.Sleep(10 * time.Millisecond)
	var keep [][]byte
	for i := 0; i < 20; i++ {
		keep = append(keep, make([]byte, 1<<16))
		runtime.GC()
	}
	stop.Store(true)
	fmt.Println("ok gcloop", len(keep))
}

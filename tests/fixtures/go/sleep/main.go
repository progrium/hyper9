// Starts goroutines that each sleep 100 ms, waits for them, and prints the
// elapsed time in milliseconds.
package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
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
}

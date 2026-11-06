// Prints the wall time in Unix nanoseconds, then the difference between
// two readings taken 10 ms apart, in nanoseconds.
package main

import (
	"fmt"
	"time"
)

func main() {
	a := time.Now()
	time.Sleep(10 * time.Millisecond)
	b := time.Now()
	fmt.Println(a.UnixNano())
	// Round(0) drops the monotonic reading, so this is wall time.
	fmt.Println(b.Round(0).Sub(a.Round(0)).Nanoseconds())
}

// Prints how many distinct microsecond values syscall.Gettimeofday gave
// in five readings 1 ms apart, then the last reading's Unix seconds.
package main

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

func main() {
	var tv syscall.Timeval
	distinct := map[int64]bool{}
	for i := 0; i < 5; i++ {
		if err := syscall.Gettimeofday(&tv); err != nil {
			fmt.Println("err:", err)
			os.Exit(1)
		}
		distinct[int64(tv.Usec)] = true
		time.Sleep(time.Millisecond)
	}
	fmt.Println(len(distinct), tv.Sec)
}

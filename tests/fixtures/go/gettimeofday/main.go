// Prints the microseconds of syscall.Gettimeofday for several readings
// 1 ms apart, then the host-comparable Unix seconds.
package main

import (
	"fmt"
	"os"
	"syscall"
	"time"
)

func main() {
	var tv syscall.Timeval
	distinct := map[int32]bool{}
	for i := 0; i < 5; i++ {
		if err := syscall.Gettimeofday(&tv); err != nil {
			fmt.Println("err:", err)
			os.Exit(1)
		}
		distinct[tv.Usec] = true
		time.Sleep(time.Millisecond)
	}
	fmt.Println(len(distinct), tv.Sec)
}

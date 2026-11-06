// Prints runtime.NumCPU and GOMAXPROCS.
package main

import (
	"fmt"
	"runtime"
)

func main() {
	fmt.Println(runtime.NumCPU(), runtime.GOMAXPROCS(0))
}

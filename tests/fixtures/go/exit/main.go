// Exits with the status in its argument, after printing to stdout.
package main

import (
	"fmt"
	"os"
	"strconv"
)

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	fmt.Println("exiting", n)
	os.Exit(n)
}

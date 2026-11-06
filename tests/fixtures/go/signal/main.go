// Waits for os.Interrupt through os/signal, then prints what it got.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"time"
)

func main() {
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt)
	fmt.Println("ready")
	select {
	case s := <-c:
		fmt.Println("got", s)
	case <-time.After(20 * time.Second):
		fmt.Println("timeout")
		os.Exit(1)
	}
}

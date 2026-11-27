// Dereferences a nil pointer and recovers from the panic.
package main

import "fmt"

type T struct{ x int }

//go:noinline
func deref(p *T) int { return p.x }

func main() {
	defer func() {
		fmt.Println("recovered:", recover())
	}()
	fmt.Println(deref(nil))
}

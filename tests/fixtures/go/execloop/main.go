// Runs itself through os/exec the number of times its second argument
// says, one after another, and prints how many children ran. Each child
// prints "child" and exits. It's design/memory-model.md's case: each fork
// shares the parent's heap copy-on-write, so the loop fits in a small
// --memory.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
)

func main() {
	if os.Getenv("H9_GO_CHILD") != "" {
		fmt.Println("child")
		return
	}
	n, err := strconv.Atoi(os.Args[2])
	if err != nil {
		fmt.Println("err:", err)
		os.Exit(1)
	}
	ran := 0
	for i := 0; i < n; i++ {
		cmd := exec.Command(os.Args[1])
		cmd.Env = append(os.Environ(), "H9_GO_CHILD=1")
		out, err := cmd.Output()
		if err != nil || string(out) != "child\n" {
			fmt.Printf("run %d: %q %v\n", i, out, err)
			os.Exit(1)
		}
		ran++
	}
	fmt.Println(ran, "ran")
}

// Re-execs itself through os/exec with H9_GO_CHILD set, and prints the
// child's output and exit status. The child prints its argument and exits
// with status 7.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
)

func main() {
	if os.Getenv("H9_GO_CHILD") != "" {
		fmt.Println("child", os.Args[1])
		os.Exit(7)
	}
	cmd := exec.Command(os.Args[1], "ok")
	cmd.Env = append(os.Environ(), "H9_GO_CHILD=1")
	out, err := cmd.Output()
	fmt.Print(string(out))
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		fmt.Println("err:", err)
		os.Exit(1)
	}
	fmt.Println("status", ee.ExitCode())
}

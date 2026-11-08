// Runs itself as a child from several goroutines at once, each locked to
// its own thread, so the thread that forks a child isn't always the one
// that waits for it, then removes a filled directory under /tmp, and
// prints "ok goexec". go build does both (design/0049-linux-threads.md).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
)

func main() {
	if len(os.Args) > 1 {
		os.Exit(len(os.Args[1]))
	}
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			runtime.LockOSThread()
			arg := fmt.Sprint(i, "xx")
			cmd := exec.Command(os.Args[0], arg)
			if err := cmd.Start(); err != nil {
				errs <- err
				return
			}
			// Wait on another thread than the one that forked.
			done := make(chan error)
			go func() { done <- cmd.Wait() }()
			err := <-done
			// The child exits with its argument's length.
			if cmd.ProcessState == nil || cmd.ProcessState.ExitCode() != len(arg) {
				errs <- fmt.Errorf("child %d: %v", i, err)
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		fmt.Println("FAIL", err)
		os.Exit(1)
	}
	d, err := os.MkdirTemp("", "goexec")
	if err == nil {
		os.MkdirAll(filepath.Join(d, "b001", "exe"), 0777)
		err = os.WriteFile(filepath.Join(d, "b001", "exe", "a.out"), []byte("x"), 0644)
	}
	if err == nil {
		err = os.RemoveAll(d)
	}
	if err != nil {
		fmt.Println("FAIL", err)
		os.Exit(1)
	}
	fmt.Println("ok goexec")
}

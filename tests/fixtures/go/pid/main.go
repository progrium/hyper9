// Prints os.Getpid and os.Getppid, then the pid and parent pid that /proc
// gives for this process.
package main

import (
	"fmt"
	"os"
	"strings"
)

func main() {
	pid := os.Getpid()
	fmt.Println(pid, os.Getppid())
	status, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		fmt.Println("status:", err)
		os.Exit(1)
	}
	ppid, err := os.ReadFile(fmt.Sprintf("/proc/%d/ppid", pid))
	if err != nil {
		fmt.Println("ppid:", err)
		os.Exit(1)
	}
	// /proc/n/status has no pid; check it names this program instead.
	fmt.Println(strings.Fields(string(status))[0], strings.TrimSpace(string(ppid)))
}

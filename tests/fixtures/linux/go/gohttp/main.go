// Fetches the URL in its argument with net/http and prints the status and
// body.
package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

func main() {
	resp, err := http.Get(os.Args[1])
	if err != nil {
		fmt.Println("err:", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Println("read:", err)
		os.Exit(1)
	}
	fmt.Println(resp.StatusCode)
	fmt.Print(string(body))
}

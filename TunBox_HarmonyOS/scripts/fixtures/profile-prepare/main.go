package main

import (
	"encoding/json"
	"io"
	"os"

	"github.com/metacubex/mihomo/config"
)

func main() {
	data, _ := io.ReadAll(os.Stdin)
	prepared, err := config.PrepareProfile(data)
	reply := struct { YAML string `json:"yaml"`; Error string `json:"error"` }{YAML:string(prepared)}
	if err != nil { reply.Error = err.Error() }
	_ = json.NewEncoder(os.Stdout).Encode(reply)
}

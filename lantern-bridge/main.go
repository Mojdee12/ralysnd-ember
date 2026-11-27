// lantern-bridge: Ember's Windows Lantern host bridge.
//
// lanternd (the radiance daemon, built with the `novpn`
// tag — see scripts/fetch-windows-sidecars.ps1) serves its
// control API over a Windows named pipe that Dart cannot
// dial. This bridge is the thin adapter: it speaks the
// daemon's own IPC client (github.com/getlantern/radiance/
// ipc) and re-serves the handful of calls Ember's Lantern
// backend needs as JSON lines on stdio — one request
// object per line, one response object per line:
//
//	{"id":1,"method":"status"}
//	{"id":1,"ok":true,"result":{...}}
//
// Methods: status, servers, connect {tag}, disconnect,
// select {tag}, addPrivate {tag,ip,port,token},
// removeServers {tags}, usage, updateConfig, quit.
// The bridge owns no state of its own; every call is a
// live IPC round-trip, so what Ember shows is always the
// daemon's own verdict.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"time"

	C "github.com/getlantern/common"
	"github.com/getlantern/radiance/common/settings"
	"github.com/getlantern/radiance/ipc"
)

type request struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type response struct {
	ID     int    `json:"id"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

func ctx() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 30*time.Second)
}

// serverDTO flattens one daemon server entry (the raw
// ServersJSON shape) into the fields Ember's picker and
// exit identity read. Unknown fields are ignored; a
// missing location reads as empty strings.
func serverDTO(raw map[string]any) map[string]any {
	dto := map[string]any{
		"tag":          str(raw["tag"]),
		"isLantern":    raw["isLantern"] == true,
		"city":         "",
		"country":      "",
		"countryCode":  "",
	}
	if loc, ok := raw["location"].(map[string]any); ok {
		dto["city"] = str(loc["city"])
		dto["country"] = str(loc["country"])
		dto["countryCode"] = str(loc["countryCode"])
	}
	return dto
}

func str(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func main() {
	client := ipc.NewClient()
	defer client.Close()

	out := bufio.NewWriter(os.Stdout)
	enc := json.NewEncoder(out)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	respond := func(r response) {
		_ = enc.Encode(r)
		_ = out.Flush()
	}

	for scanner.Scan() {
		var req request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			continue
		}
		if req.Method == "quit" {
			respond(response{ID: req.ID, OK: true})
			return
		}
		result, err := dispatch(client, req)
		if err != nil {
			respond(response{ID: req.ID, OK: false, Error: err.Error()})
			continue
		}
		respond(response{ID: req.ID, OK: true, Result: result})
	}
}

func dispatch(client *ipc.Client, req request) (any, error) {
	c, cancel := ctx()
	defer cancel()
	params := map[string]any{}
	if len(req.Params) > 0 {
		_ = json.Unmarshal(req.Params, &params)
	}
	switch req.Method {
	case "status":
		status, err := client.VPNStatus(c)
		if err != nil {
			return nil, err
		}
		result := map[string]any{"vpnStatus": status.String()}
		if sel, found, err := client.SelectedServer(c); err == nil && found && sel != nil {
			raw, _ := json.Marshal(sel)
			var m map[string]any
			if json.Unmarshal(raw, &m) == nil {
				result["selected"] = serverDTO(m)
			}
		}
		return result, nil
	case "servers":
		raw, err := client.ServersJSON(c)
		if err != nil {
			return nil, err
		}
		var list []map[string]any
		if err := json.Unmarshal(raw, &list); err != nil {
			return nil, err
		}
		servers := make([]any, 0, len(list))
		for _, entry := range list {
			servers = append(servers, serverDTO(entry))
		}
		return map[string]any{"servers": servers}, nil
	case "connect":
		return nil, client.ConnectVPN(c, str(params["tag"]))
	case "disconnect":
		return nil, client.DisconnectVPN(c)
	case "select":
		return nil, client.SelectServer(c, str(params["tag"]))
	case "addPrivate":
		port, _ := params["port"].(float64)
		return nil, client.AddPrivateServer(
			c,
			str(params["tag"]),
			str(params["ip"]),
			int(port),
			str(params["token"]),
			C.ServerLocation{},
			false,
		)
	case "removeServers":
		tags := []string{}
		if raw, ok := params["tags"].([]any); ok {
			for _, t := range raw {
				tags = append(tags, str(t))
			}
		}
		return nil, client.RemoveServers(c, tags)
	case "usage":
		u, err := client.VPNUsage(c)
		if err != nil {
			return nil, err
		}
		t := u.ThisMonth
		up := t.Proxyless.Up + t.Personal.Up + t.Private.Up + t.Lantern.Up + t.Direct.Up
		down := t.Proxyless.Down + t.Personal.Down + t.Private.Down + t.Lantern.Down + t.Direct.Down
		return map[string]any{"up": up, "down": down}, nil
	case "updateConfig":
		return nil, client.UpdateConfig(c)
	case "smartRouting":
		// Read or set the daemon's smart-routing setting
		// (the same key the official client patches). With
		// "on" absent it only reads.
		if v, ok := params["on"]; ok {
			on, _ := v.(bool)
			if _, err := client.PatchSettings(c, settings.Settings{
				settings.SmartRoutingKey: on,
			}); err != nil {
				return nil, err
			}
			return map[string]any{"smartRouting": on}, nil
		}
		s, err := client.Settings(c)
		if err != nil {
			return nil, err
		}
		on, _ := s[settings.SmartRoutingKey].(bool)
		return map[string]any{"smartRouting": on}, nil
	}
	return nil, &methodError{method: req.Method}
}

type methodError struct{ method string }

func (e *methodError) Error() string { return "unknown method: " + e.method }

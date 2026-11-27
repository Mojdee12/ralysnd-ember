// The wire protocol of the Ralysnd Ember service: JSON lines on
// a named pipe, every frame carrying the protocol version. A
// request is {"v":1,"id":N,"method":"...","params":{...}}; its
// response is {"v":1,"id":N,"ok":true,"result":{...}} or
// {"v":1,"id":N,"ok":false,"error":"..."}. Unsolicited frames
// are events: {"v":1,"event":"proc.output",...}.
//
// The contract is deliberately engine-agnostic: the service owns
// process and TUN-session lifecycles behind generic primitives
// (proc.*, tun.*) so an engine's binary can be swapped without
// the service changing. Engine semantics — argv shapes, output
// parsing, connect proofs — stay with the app's controllers.
package main

import "encoding/json"

const protocolVersion = 1

type request struct {
	V      int             `json:"v"`
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

type response struct {
	V      int         `json:"v"`
	ID     int         `json:"id"`
	OK     bool        `json:"ok"`
	Result interface{} `json:"result,omitempty"`
	Error  string      `json:"error,omitempty"`
}

type event struct {
	V     int                    `json:"v"`
	Event string                 `json:"event"`
	Data  map[string]interface{} `json:"data"`
}

func encodeLine(v interface{}) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

func paramsInto(raw json.RawMessage, dst interface{}) error {
	if len(raw) == 0 {
		return nil
	}
	return json.Unmarshal(raw, dst)
}

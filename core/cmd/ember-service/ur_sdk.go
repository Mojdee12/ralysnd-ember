//go:build ur_sdk

package main

// The REAL URnetwork SDK binding — compiled only with
// `-tags ur_sdk`.
//
// BUILD NOTE (why the tag exists): the vendor module
// github.com/urnetwork/sdk/v2026 (pin v2026.11.22-1105365180,
// the version the 2041 compile probe proved for windows/amd64
// with CGO_ENABLED=0) declares `go 1.27.4`. Since SVC-UR2,
// core/go.mod pins `go 1.27.4` and requires the SDK, and
// scripts/build-windows.ps1 builds the service with
// `-tags ur_sdk` — that tagged build is what ships. The tag
// still exists so the default build (and the contract suite,
// which builds WITHOUT tags) carries the full ur.* contract
// with available=false (see ur.go) — never a faked engine —
// and so the SDK's dependency tree stays out of the other
// cores' builds.
//
// What this binding does, at the DeviceLocal level (the
// vendor's ConnectViewController is NEVER used — it forces
// ProvideModePublic on sign-in):
//
//   - NetworkSpace via NewNetworkSpaceManagerNoStorage +
//     UpdateNetworkSpaceValues("bringyour.com"/"prod"), the
//     vendor's own embed pattern (and the 2041 probe's).
//   - Device via NewDeviceLocalWithDefaults(space, clientJWT,
//     description, "windows", appVersion, NewId(), rpc=false).
//   - ProvideModeNone set + read back before any connect.
//   - Destination via Reconnect(ConnectLocation): Best
//     Available = ConnectLocationId{BestAvailable:true}; a
//     country pick resolves through the API's FindLocations and
//     sets ConnectLocationId.LocationId (the 2157 lesson: a
//     destination whose connect_location_id is null is rejected
//     by the SDK, so it is always populated here).
//   - Connected state from GetConnectedProviderLocations —
//     the SDK's derived list of established, identity-verified
//     provider sessions.
//
// DATA PLANE (SVC-UR2): DeviceLocal moves raw IP packets via
// SendPacket / AddReceivePacketCallback; the host owns the TUN
// side. The pump lives in ur_pump.go (lifecycle) +
// ur_pump_windows.go (the Wintun adapter) and this binding
// exposes the packet plane through the urPumpDevice methods
// at the bottom of this file. ur.status.tunneled is the
// pump's own running state, reported by ur.go's manager.

import (
	"fmt"
	"strings"
	"time"

	connect "github.com/urnetwork/connect/v2026"
	"github.com/urnetwork/connect/v2026/protocol"
	sdk "github.com/urnetwork/sdk/v2026"

	"github.com/armanlife/firefox-vpn-client/core/internal/version"
)

func init() {
	urDeviceFactory = newURSDKDevice
}

type urSDKDevice struct {
	spaceManager *sdk.NetworkSpaceManager
	device       *sdk.DeviceLocal
}

func newURSDKDevice(jwt string) (urDevice, error) {
	manager := sdk.NewNetworkSpaceManagerNoStorage()
	space := manager.UpdateNetworkSpaceValues(
		sdk.NewNetworkSpaceKey("bringyour.com", "prod"),
		&sdk.NetworkSpaceValues{Bundled: true},
	)
	if space == nil {
		manager.Close()
		return nil, fmt.Errorf("the SDK returned no network space for bringyour.com/prod")
	}
	dev, err := sdk.NewDeviceLocalWithDefaults(
		space,
		jwt,
		"Ralysnd Ember (Windows service)",
		"windows",
		version.Current,
		sdk.NewId(),
		false,
	)
	if err != nil {
		manager.Close()
		return nil, err
	}
	return &urSDKDevice{spaceManager: manager, device: dev}, nil
}

// PinProvidingOff pins ProvideModeNone and verifies the SDK
// actually holds it — the read-back is the proof, not the set.
func (d *urSDKDevice) PinProvidingOff() error {
	d.device.SetProvideMode(sdk.ProvideModeNone)
	if got := d.device.GetProvideMode(); got != sdk.ProvideModeNone {
		return fmt.Errorf("providing could not be pinned OFF (the SDK reports provide mode %d) — refusing to connect", got)
	}
	return nil
}

func (d *urSDKDevice) Connect(country string) error {
	loc := &sdk.ConnectLocation{}
	country = strings.TrimSpace(country)
	if country == "" {
		loc.ConnectLocationId = &sdk.ConnectLocationId{BestAvailable: true}
		loc.Name = "Best Available"
	} else {
		resolved, err := d.resolveCountry(country)
		if err != nil {
			return err
		}
		loc = resolved
	}
	// Reconnect is the SDK's explicit "connect to this" action:
	// it always rebuilds the connection for the destination.
	d.device.Reconnect(loc)
	return nil
}

// resolveCountry maps a picker id or a country name to a
// ConnectLocation whose ConnectLocationId is always populated.
func (d *urSDKDevice) resolveCountry(country string) (*sdk.ConnectLocation, error) {
	countries, err := d.findLocations()
	if err != nil {
		return nil, err
	}
	for _, c := range countries {
		if c.locationId == nil {
			continue
		}
		if strings.EqualFold(c.id, country) || strings.EqualFold(c.name, country) {
			return &sdk.ConnectLocation{
				ConnectLocationId: &sdk.ConnectLocationId{LocationId: c.locationId},
				Name:              c.name,
				Country:           c.name,
				LocationType:      sdk.LocationTypeCountry,
				CountryLocationId: c.locationId,
			}, nil
		}
	}
	return nil, fmt.Errorf("the SDK location list has no country %q", country)
}

func (d *urSDKDevice) Disconnect() {
	d.device.RemoveDestination()
}

func (d *urSDKDevice) Connected() (bool, string) {
	list := d.device.GetConnectedProviderLocations()
	if list == nil || list.Len() == 0 {
		return false, ""
	}
	first := list.Get(0)
	if first == nil {
		return true, ""
	}
	return true, first.Country
}

type urFoundLocation struct {
	id         string
	name       string
	locationId *sdk.Id
}

// findLocations runs the API's FindLocations with an empty
// query (the full location catalogue) and keeps the country
// entries. The SDK API is callback-shaped; this bridges it to
// a bounded synchronous call.
func (d *urSDKDevice) findLocations() ([]urFoundLocation, error) {
	type outcome struct {
		result *sdk.FindLocationsResult
		err    error
	}
	ch := make(chan outcome, 1)
	cb := sdk.FindLocationsCallback(connect.NewApiCallback(func(result *sdk.FindLocationsResult, err error) {
		ch <- outcome{result: result, err: err}
	}))
	d.device.GetApi().FindLocations(&sdk.FindLocationsArgs{Query: ""}, cb)
	select {
	case o := <-ch:
		if o.err != nil {
			return nil, o.err
		}
		if o.result == nil || o.result.Locations == nil {
			return nil, fmt.Errorf("the SDK returned no locations")
		}
		var out []urFoundLocation
		for i := 0; i < o.result.Locations.Len(); i++ {
			lr := o.result.Locations.Get(i)
			if lr == nil || lr.LocationId == nil {
				continue
			}
			if lr.LocationType != sdk.LocationTypeCountry {
				continue
			}
			out = append(out, urFoundLocation{
				id:         lr.LocationId.String(),
				name:       lr.Name,
				locationId: lr.LocationId,
			})
		}
		return out, nil
	case <-time.After(30 * time.Second):
		return nil, fmt.Errorf("the SDK location lookup timed out")
	}
}

func (d *urSDKDevice) Countries() ([]urCountry, error) {
	found, err := d.findLocations()
	if err != nil {
		return nil, err
	}
	out := make([]urCountry, 0, len(found))
	for _, f := range found {
		out = append(out, urCountry{ID: f.id, Name: f.name})
	}
	return out, nil
}

func (d *urSDKDevice) Close() {
	d.device.Close()
	d.spaceManager.Close()
}

// ---- packet plane (urPumpDevice, SVC-UR2) ------------------
// The pump in ur_pump.go drives the device through these;
// see that file's header for the SDK's host contract.

func (d *urSDKDevice) SendPacket(packet []byte) bool {
	return d.device.SendPacket(packet, int32(len(packet)))
}

func (d *urSDKDevice) AddReceivePacketCallback(cb func(packet []byte)) func() {
	return d.device.AddReceivePacketCallback(
		func(_ connect.TransferPath, _ protocol.ProvideMode, _ *connect.IpPath, packet []byte) {
			cb(packet)
		})
}

func (d *urSDKDevice) SetTunnelStarted(started bool) {
	d.device.SetTunnelStarted(started)
}

// SetEgressInterface pins ALL of the connect stack's egress
// sockets to the physical interface (the pin is a connect
// package global by the SDK's own design — see
// connect/egress.go); this service hosts exactly one connect
// consumer, this device.
func (d *urSDKDevice) SetEgressInterface(index4, index6 uint32) {
	connect.SetEgressInterfaceIndex(index4, index6)
}

func (d *urSDKDevice) TunnelConfig() urPumpConfig {
	cfg := urPumpConfig{
		Address4:   d.device.TunnelLocalAddress(),
		Address6:   d.device.TunnelLocalAddressIpv6(),
		PrefixLen6: sdk.TunnelLocalPrefixLengthIpv6,
		MTU:        urTunnelMTU,
	}
	if list := d.device.TunnelDnsAddressesIpv4(); list != nil {
		for i := 0; i < list.Len(); i++ {
			if s := list.Get(i); s != "" {
				cfg.DNS4 = append(cfg.DNS4, s)
			}
		}
	}
	if list := d.device.TunnelDnsAddressesIpv6(); list != nil {
		for i := 0; i < list.Len(); i++ {
			if s := list.Get(i); s != "" {
				cfg.DNS6 = append(cfg.DNS6, s)
			}
		}
	}
	return cfg
}

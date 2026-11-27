package mobile

import "testing"

// Build 2038 (Iran-priority queue 2f, custom tunnel MTU): the app sets
// the tunnel MTU before StartTun; the value is clamped 1280..1500 so a
// corrupt or out-of-range stored value can never break a connect.
func TestSetTunMTUClamps(t *testing.T) {
	defer SetTunMTU(1500)
	cases := []struct {
		in   int32
		want uint32
	}{
		{900, 1280},   // below the IPv6 minimum: the floor
		{1279, 1280},  // just under the floor
		{1280, 1280},  // the floor itself
		{1400, 1400},  // a offered preset
		{1420, 1420},  // the WireGuard-standard preset
		{1500, 1500},  // the default
		{9000, 1500},  // jumbo: the ceiling
		{-5, 1280},    // nonsense: the floor
	}
	for _, c := range cases {
		SetTunMTU(c.in)
		if tunMTU != c.want {
			t.Errorf("SetTunMTU(%d): got %d, want %d", c.in, tunMTU, c.want)
		}
	}
}

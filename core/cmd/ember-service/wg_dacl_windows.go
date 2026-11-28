//go:build windows

package main

import (
	"fmt"

	"golang.org/x/sys/windows"
)

// secureWGStoreDir applies a restrictive DACL to the
// WireGuard config store (review W10): the folder holds
// tunnel configs with private keys, and Go's 0o700 mode sets
// no Windows ACL — under ProgramData the inherited default
// would leave it readable by other local users. The DACL is
// protected (inheritance cut) and grants full control to
// SYSTEM and BUILTIN\Administrators only; entries inherit
// onto the config files created inside.
func secureWGStoreDir(dir string) error {
	systemSID, err := windows.CreateWellKnownSid(windows.WinLocalSystemSid)
	if err != nil {
		return fmt.Errorf("system sid: %w", err)
	}
	adminsSID, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return fmt.Errorf("administrators sid: %w", err)
	}
	entry := func(sid *windows.SID, trusteeType windows.TRUSTEE_TYPE) windows.EXPLICIT_ACCESS {
		return windows.EXPLICIT_ACCESS{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.GRANT_ACCESS,
			Inheritance:       windows.OBJECT_INHERIT_ACE | windows.CONTAINER_INHERIT_ACE,
			Trustee: windows.TRUSTEE{
				TrusteeForm:  windows.TRUSTEE_IS_SID,
				TrusteeType:  trusteeType,
				TrusteeValue: windows.TrusteeValueFromSID(sid),
			},
		}
	}
	acl, err := windows.ACLFromEntries([]windows.EXPLICIT_ACCESS{
		entry(systemSID, windows.TRUSTEE_IS_USER),
		entry(adminsSID, windows.TRUSTEE_IS_GROUP),
	}, nil)
	if err != nil {
		return fmt.Errorf("build the config store DACL: %w", err)
	}
	if err := windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, acl, nil); err != nil {
		return fmt.Errorf("apply the config store DACL: %w", err)
	}
	return nil
}

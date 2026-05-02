package main

import (
	"github.com/spf13/cobra"
)

// completeAccounts returns Cobra-style completions of every configured account
// identifier (alias, name, or email — same set used by GetAccountByIdentifier).
//
// Usage:
//
//	cmd.ValidArgsFunction = completeAccounts
//	cmd.RegisterFlagCompletionFunc("account", completeAccounts)
func completeAccounts(_ *cobra.Command, _ []string, _ string) ([]string, cobra.ShellCompDirective) {
	cfg := GetConfig()
	if cfg == nil {
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
	return cfg.ListAccountIdentifiers(), cobra.ShellCompDirectiveNoFileComp
}

package main

import (
	"regexp"
	"strings"

	"github.com/fatih/color"
	"github.com/spf13/cobra"
)

// Cobra usage template with colored output: bold-yellow section headers,
// bold-green command/flag names, plain-green argument placeholders.
// Descriptions stay default. fatih/color respects NO_COLOR and isatty.
const usageTemplate = `{{header "Usage:"}}{{if .Runnable}}
  {{useLine .UseLine}}{{end}}{{if .HasAvailableSubCommands}}
  {{name .CommandPath}} {{arg "[command]"}}{{end}}{{if gt (len .Aliases) 0}}

{{header "Aliases:"}}
  {{.NameAndAliases}}{{end}}{{if .HasAvailableSubCommands}}

{{header "Available Commands:"}}{{range .Commands}}{{if (or .IsAvailableCommand (eq .Name "help"))}}
  {{cmdPad .Name .NamePadding}} {{.Short}}{{end}}{{end}}{{end}}{{if .HasAvailableLocalFlags}}

{{header "Flags:"}}
{{.LocalFlags.FlagUsages | trimTrailingWhitespaces | colorFlags}}{{end}}{{if .HasAvailableInheritedFlags}}

{{header "Global Flags:"}}
{{.InheritedFlags.FlagUsages | trimTrailingWhitespaces | colorFlags}}{{end}}{{if .HasHelpSubCommands}}

{{header "Additional help topics:"}}{{range .Commands}}{{if .IsAdditionalHelpTopicCommand}}
  {{rpad .CommandPath .CommandPathPadding}} {{.Short}}{{end}}{{end}}{{end}}{{if .HasAvailableSubCommands}}

Use "{{name (printf "%s [command] --help" .CommandPath)}}" for more information about a command.{{end}}
`

const helpTemplate = `{{with (or .Long .Short)}}{{. | trimTrailingWhitespaces}}

{{end}}{{if or .Runnable .HasSubCommands}}{{.UsageString}}{{end}}`

// flagLineRegex matches a single line from pflag's FlagUsages output.
// Groups: 1=indent, 2=flag-spec, 3=type-placeholder (optional), 4=padding, 5=description
// Examples it matches:
//
//	"  -h, --help             help for command"
//	"      --debug            enable debug logging"
//	"  -c, --config string   config file (default: ...)"
var flagLineRegex = regexp.MustCompile(`^(\s+)((?:-\w, )?--[\w-]+)( \S+)?(\s+)(.*)$`)

// installColoredHelp wires up colored templates on the given root command.
// All subcommands inherit these templates automatically via Cobra.
func installColoredHelp(root *cobra.Command) {
	headerStyle := color.New(color.FgYellow, color.Bold).SprintFunc()
	nameStyle := color.New(color.FgGreen, color.Bold).SprintFunc()
	argStyle := color.New(color.FgGreen).SprintFunc()

	cobra.AddTemplateFunc("header", func(s string) string { return headerStyle(s) })
	cobra.AddTemplateFunc("name", func(s string) string { return nameStyle(s) })
	cobra.AddTemplateFunc("arg", func(s string) string { return argStyle(s) })

	// useLine: split "durian search [flags] [query]" → bold-green command,
	// plain-green for argument tokens.
	cobra.AddTemplateFunc("useLine", func(line string) string {
		parts := strings.SplitN(line, " ", 2)
		if len(parts) == 1 {
			return nameStyle(parts[0])
		}
		return nameStyle(parts[0]) + " " + argStyle(parts[1])
	})

	// cmdPad: pad command name to width AFTER coloring. ANSI codes inflate
	// string length so Cobra's rpad helper would compute the wrong width.
	cobra.AddTemplateFunc("cmdPad", func(name string, width int) string {
		pad := width - len(name)
		if pad < 0 {
			pad = 0
		}
		return nameStyle(name) + strings.Repeat(" ", pad)
	})

	// colorFlags: parse the output of pflag's FlagUsages line by line and
	// recolor flag specs (bold green) and value placeholders (plain green).
	// Padding spaces are preserved so column alignment with descriptions stays.
	cobra.AddTemplateFunc("colorFlags", func(s string) string {
		var sb strings.Builder
		lines := strings.Split(s, "\n")
		for i, line := range lines {
			m := flagLineRegex.FindStringSubmatch(line)
			if m == nil {
				sb.WriteString(line)
			} else {
				sb.WriteString(m[1])
				sb.WriteString(nameStyle(m[2]))
				if m[3] != "" {
					sb.WriteString(" ")
					sb.WriteString(argStyle(strings.TrimSpace(m[3])))
				}
				sb.WriteString(m[4])
				sb.WriteString(m[5])
			}
			if i < len(lines)-1 {
				sb.WriteString("\n")
			}
		}
		return sb.String()
	})

	root.SetUsageTemplate(usageTemplate)
	root.SetHelpTemplate(helpTemplate)
}

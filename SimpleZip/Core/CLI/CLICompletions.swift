//
//  CLICompletions.swift
//  SimpleZip
//
//  0.4.4 #48:`simplezip completions <zsh|bash|fish>` 打印对应 shell 的补全脚本到 stdout。
//  用户把它存进各自 shell 的补全目录即可(脚本头部注释给了安装命令)。CLI 全程英文(A19)。
//

import Foundation

nonisolated enum CLICompletions {
    enum Shell: String, CaseIterable {
        case zsh, bash, fish
    }

    static func script(for shell: Shell) -> String {
        switch shell {
        case .zsh: return zshScript
        case .bash: return bashScript
        case .fish: return fishScript
        }
    }

    // 子命令列表与 CLIInvocation.knownCommands 对应(改命令时这里要跟）。
    private static let zshScript = """
    #compdef simplezip
    # Install: simplezip completions zsh > "${fpath[1]}/_simplezip" (then restart the shell)
    _simplezip() {
      local -a commands
      commands=(
        'help:Show help'
        'version:Show the version'
        'doctor:Check the environment'
        'open:Open archives in the app'
        'list:List archive contents'
        'check:Test archive integrity'
        'inspect:Release-package check'
        'compare:Compare two archives'
        'create:Create an archive'
        'extract:Extract an archive'
        'verify:Verify a checksum file'
        'hash:Compute checksums'
        'completions:Print a shell completion script'
      )
      if (( CURRENT == 2 )); then
        _describe 'command' commands
        return
      fi
      case ${words[2]} in
        create)
          _arguments \\
            '(-t --template)'{-t,--template}'[Apply a saved template]:template:' \\
            '(-l --level)'{-l,--level}'[Compression level 0-9]:level:(0 1 2 3 4 5 6 7 8 9)' \\
            '--exclude-junk[Exclude macOS junk files]' \\
            '--reproducible[Reproducible archive]' \\
            '--encrypt[Encrypt (password via SIMPLEZIP_PASSWORD or tty)]' \\
            '--json[JSON output]' '--quiet[Errors only]' '--verbose[Raw backend output]' \\
            '*:file:_files'
          ;;
        hash)
          _arguments \\
            '(-a --algo)'{-a,--algo}'[Algorithms (comma-separated, or all)]:algorithms:' \\
            '--json[JSON output]' '--quiet[Errors only]' \\
            '*:file:_files'
          ;;
        extract)
          _arguments \\
            '(-d --to)'{-d,--to}'[Destination parent folder]:directory:_files -/' \\
            '--json[JSON output]' '--quiet[Errors only]' \\
            '*:file:_files'
          ;;
        completions) _values 'shell' zsh bash fish ;;
        help) _values 'command' help version doctor open list check inspect compare create extract verify hash completions ;;
        *) _arguments '--json[JSON output]' '--quiet[Errors only]' '--verbose[Raw backend output]' '*:file:_files' ;;
      esac
    }
    _simplezip "$@"
    """

    private static let bashScript = """
    # bash completion for simplezip
    # Install: simplezip completions bash > /usr/local/etc/bash_completion.d/simplezip
    _simplezip() {
      local cur commands
      cur="${COMP_WORDS[COMP_CWORD]}"
      commands="help version doctor open list check inspect compare create extract verify hash completions"
      if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return
      fi
      case "${COMP_WORDS[1]}" in
        create)
          COMPREPLY=( $(compgen -W "--template --level --exclude-junk --reproducible --encrypt --json --quiet --verbose" -- "$cur") $(compgen -f -- "$cur") )
          ;;
        hash)
          COMPREPLY=( $(compgen -W "--algo --json --quiet" -- "$cur") $(compgen -f -- "$cur") )
          ;;
        extract)
          COMPREPLY=( $(compgen -W "--to --json --quiet" -- "$cur") $(compgen -f -- "$cur") )
          ;;
        completions) COMPREPLY=( $(compgen -W "zsh bash fish" -- "$cur") ) ;;
        help) COMPREPLY=( $(compgen -W "$commands" -- "$cur") ) ;;
        *) COMPREPLY=( $(compgen -W "--json --quiet --verbose" -- "$cur") $(compgen -f -- "$cur") ) ;;
      esac
    }
    complete -F _simplezip simplezip
    """

    private static let fishScript = """
    # fish completion for simplezip
    # Install: simplezip completions fish > ~/.config/fish/completions/simplezip.fish
    complete -c simplezip -f
    complete -c simplezip -n __fish_use_subcommand -a help -d 'Show help'
    complete -c simplezip -n __fish_use_subcommand -a version -d 'Show the version'
    complete -c simplezip -n __fish_use_subcommand -a doctor -d 'Check the environment'
    complete -c simplezip -n __fish_use_subcommand -a open -d 'Open archives in the app'
    complete -c simplezip -n __fish_use_subcommand -a list -d 'List archive contents'
    complete -c simplezip -n __fish_use_subcommand -a check -d 'Test archive integrity'
    complete -c simplezip -n __fish_use_subcommand -a inspect -d 'Release-package check'
    complete -c simplezip -n __fish_use_subcommand -a compare -d 'Compare two archives'
    complete -c simplezip -n __fish_use_subcommand -a create -d 'Create an archive'
    complete -c simplezip -n __fish_use_subcommand -a extract -d 'Extract an archive'
    complete -c simplezip -n __fish_use_subcommand -a verify -d 'Verify a checksum file'
    complete -c simplezip -n __fish_use_subcommand -a hash -d 'Compute checksums'
    complete -c simplezip -n __fish_use_subcommand -a completions -d 'Print a shell completion script'
    complete -c simplezip -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
    complete -c simplezip -n '__fish_seen_subcommand_from hash' -s a -l algo -d 'Algorithms (comma-separated, or all)'
    complete -c simplezip -n '__fish_seen_subcommand_from extract' -s d -l to -d 'Destination parent folder'
    complete -c simplezip -n '__fish_seen_subcommand_from create' -s t -l template -d 'Apply a saved template'
    complete -c simplezip -n '__fish_seen_subcommand_from create' -s l -l level -d 'Compression level 0-9'
    complete -c simplezip -n '__fish_seen_subcommand_from create' -l exclude-junk -d 'Exclude macOS junk files'
    complete -c simplezip -n '__fish_seen_subcommand_from create' -l reproducible -d 'Reproducible archive'
    complete -c simplezip -n '__fish_seen_subcommand_from create' -l encrypt -d 'Encrypt (password via env/tty)'
    complete -c simplezip -l json -d 'JSON output'
    complete -c simplezip -s q -l quiet -d 'Errors only'
    complete -c simplezip -l verbose -d 'Raw backend output'
    """
}

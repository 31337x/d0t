set -l fzf_theme_opts "\
--color=bg+:#2a2a37
--color=bg:#1f1f28
--color=spinner:#c4b28a
--color=hl:#c4746e
--color=fg:#dcd7ba
--color=header:#c4746e
--color=info:#c4b28a
--color=pointer:#c4b28a
--color=marker:#c8c093
--color=fg+:#dcd7ba
--color=prompt:#c4b28a
--color=hl+:#c4746e
--color=selected-bg:#393836
--color=border:#363646
--color=label:#dcd7ba"

if set -q FZF_DEFAULT_OPTS[1]; and test -n "$FZF_DEFAULT_OPTS"
    set -Ux FZF_DEFAULT_OPTS "$FZF_DEFAULT_OPTS
$fzf_theme_opts"
else
    set -Ux FZF_DEFAULT_OPTS "$fzf_theme_opts"
end

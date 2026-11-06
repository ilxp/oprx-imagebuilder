# .bashrc

# 1. 防止按 Ctrl+S 导致终端假死
stty -ixon

# 2. 环境与历史记录优化
export HISTSIZE=1000
export HISTFILESIZE=2000
export HISTCONTROL=ignoreboth:erasedups  # 忽略重复命令和空格开头的命令

# 3. 安全别名 (保留你原有的安全防护)
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# 4. 增强的 ls 颜色与别名
export LS_OPTIONS='--color=auto'
# 兼容 OpenWrt 没装 coreutils-dircolors 的情况
if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors)"
fi

alias ls='ls $LS_OPTIONS'
alias ll='ls $LS_OPTIONS -lh'
alias la='ls $LS_OPTIONS -Ah'
alias l='ls $LS_OPTIONS -CF'
alias grep='grep --color=auto'

# 5. 常用快捷命令
alias df='df -h'
alias free='free -m'
alias ..='cd ..'
alias ...='cd ../..'

# 6. 炫酷的彩色提示符 (绿色用户名，蓝色路径)
# 格式如：root@OprX:~#
export PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# Source global definitions
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi
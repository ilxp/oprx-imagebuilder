# .bash_profile
if [ -f ~/.bashrc ]; then
	. ~/.bashrc
fi

# User specific environment and startup programs
# 兼容 OpenWrt 的默认路径
PATH=$PATH:$HOME/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# enhance sudo to handle functions just as well with some slowdown
function sudo() {
	if [[ "$1" != -* ]]; then
		function foo() { return 0; }
		local functionType="$(type foo | head -n 1)"  # because of locale reasons
		if [ "$(type "$1" | head -n 1)" = "${functionType/#foo/"$1"}" ]; then
			local functionName="$1"
			shift
			/bin/sudo bash -c "
				function $(type "$functionName" | tail -n +2)
				${functionName@Q} ${@@Q}
			"
			return $?
		fi
	fi
	sudo "$@"
}

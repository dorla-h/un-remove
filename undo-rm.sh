alias delete="/usr/bin/rm"

# based on https://stackoverflow.com/a/78094638
# only disadvantage: the interaction is slow, it first needs to process all of `find` before code can proceed
qfind() {
	while IFS='' read -r -d $'\0' findOutput; do
		/bin/echo -n "${findOutput@Q} "
	done < <(/usr/bin/find "$@" -print0)
}

# lists all leaves in the file system structure (files and empty directories), quoted
qfind-leaves() {
	for arg do
		qfind "$arg" -type f
		qfind "$arg" -type d -empty
	done
}

# without dereference of links
get-absolute-path() {
	local destinationPath="$1"
	[ -n "${destinationPath%%/*}" ] && destinationPath="$(pwd)/$destinationPath"
	destinationPath="$(/usr/bin/sed -E -e 's;/+;/;g' <<<"$destinationPath")"

	# escaped slashes are no thing in Linux, slashes are turned into unicode for filenames
	while /bin/echo "$destinationPath" | /usr/bin/grep -E '/\.(/|$)' &>/dev/null; do
		destinationPath="$(/usr/bin/sed -E -e 's;/\.(/|$);/;' <<<"$destinationPath")"
	done

	while /bin/echo "$destinationPath" | /usr/bin/grep -E '/[^/]+/\.\.($|/)' &>/dev/null; do
		destinationPath="$(/usr/bin/sed -E -e 's;/[^/]+/\.\.(/|$);/;' <<<"$destinationPath")"
	done

	/bin/echo -n "${destinationPath}"
}

get-mountpoint() {
	local mountpoint="$(/usr/bin/df --output=target "$1" 2>/dev/null | /usr/bin/sed -n '2p')"
	if ! [ -d "$mountpoint" ]; then
		local mountpoint="$1"
		until [ "$mountpoint" = '/' ] || /usr/bin/mountpoint "$mountpoint" &>/dev/null; do
			mountpoint="$(/usr/bin/dirname "$mountpoint")"
		done
	fi

	/bin/echo -n "${mountpoint}"
}

# finds the closest trash directory in a parent directory
# The first argument doesn't need to be an existing file path; the 2nd argument is optional and contains the trash directory name to search for.
get-trash-dir() {
	local filePath="$1"
	local TMP_TRASH="${2:-"$(tmp-trash-dir)"}"

	until [ "$filePath" == '/' ]; do
		filePath="$(/usr/bin/dirname "$filePath")"
		local trashDir
		if /usr/bin/mountpoint "$filePath" &>/dev/null && trashDir="${filePath%/}/${TMP_TRASH}" && [ -d "${trashDir}" ]
		then
			/bin/echo -n "${trashDir%/}"
			return 0
		fi
	done

	if [ "$1" = '/' ]; then /bin/echo "There is no trash directory for “/” because it cannot be removed." 1>&2; fi
	/bin/echo -n "/${TMP_TRASH%/}"
	return 1
}

tmp-trash-dir() {
	if (( $# > 0 )); then
		/bin/echo -n "$(get-mountpoint "$1" 2>/dev/null)/"
	fi
	/bin/echo -n ".tmp-trash-$(id -u)"
}

# outputs the filepath in the trash which corresponds to the filepath arguments
get-trash-path() {
	local trashName=${TMP_TRASH:-"$(tmp-trash-dir)"}

	declare $DECLARE destinationPath="$(get-absolute-path "$1")"
	declare $DECLARE trashDir="$(TMP_TRASH="$trashName" get-trash-dir "$destinationPath")" || return $?
	declare $DECLARE mountpoint="$(TMP_TRASH="$trashName" --mountpoint-from-trashDir "$trashDir")"
	if [[ "${destinationPath%/}/" = "${trashDir}/"* ]]; then
		declare $DECLARE pathInTrash="$destinationPath"
	else
		declare $DECLARE pathInTrash="${destinationPath/#"${mountpoint}"/"${trashDir}"}"
	fi
	/bin/echo -n "$pathInTrash"
}

--mk-destination-dir() {
	local filePath="$1"
	local oldPrefix="$2"
	local newPrefix="$3"

	local destDir="$(/usr/bin/dirname "${filePath/#"${oldPrefix%/}"/"${newPrefix%/}"}")"
	[ -z "${DEBUG+y}" ] && /usr/bin/mkdir -p "$destDir"
	/bin/echo -n "$destDir"
}

--mountpoint-from-trashDir() {
	/bin/echo -n "${1%"/${TMP_TRASH}"}"
}

declare fileRetentionDuration=$((12 * 60 * 60 )) # in seconds
declare -a unremovableFilePaths=('/')
# a map for faster lookup, paths with a length of ≤ 3 warn automatically
declare -A importantDirectories=(
	["$HOME/.local/share"]=  # XDG_DATA_HOME
	["$HOME/.local/state"]=  # XDG_STATE_HOME
	["$HOME/.local/bin"]=  # local executables could be here
)

alias rmm="rm -m"

trash-rm() {
	local files=()
	for arg do
		files+=("$(get-trash-path "$arg")")
	done
	${DEBUG+"/bin/echo" "preview:"} undo-rm --delete -f "${files[@]}"
}


path-exists() {
	ls "$1" &>/dev/null    # fixed bug: [ -e "…"] does not return true for (broken) links
	return $?
}

# The idea is to cp files to a temporary trash location before being deleted with `rm`.
# It copies all (valid and confirmed) input files and will only keep those copies of actually removed items.
# This is a disadvantage if you want to avoid writes to a device. It's slow too and it will lose it's original birth time.
# This design of copying files is used to preserve the API of `rm`.
# Use the new option '-m' to move the files to the trash (no copies will be made) while using the API of `mv`.
# With '-m' it will call 'mv' for each provided file path (due to individual destination directories in the trash).
# A trash directory must be writable and located at the root of each item's partition.
# If a trash directory cannot be made, and "-f" is used, it will just remove the associated files without having copied them.
# But if '-f' fails with '-m' it only will throw an error message that it cannot find the target or move the items
# (and it won't remove anything).
# Call it with DEBUG=<number> variable to see verbose information about the process (dry run, nothing will be removed).
rm() {(
	local debugCommand=${DEBUG+"/bin/echo" "preview:"}
	if (( $# < 1 )); then /usr/bin/rm; return $?; fi
	if [ "$*" = -m ]; then /usr/bin/mv; return $?; fi

	shopt -s dotglob

	TMP_TRASH="${TMP_TRASH:-"$(tmp-trash-dir)"}"
	# parse options and filenames
	local options=()
	local files=()
	local isRemovingDirectories
	local isForcing
	local isMoving

	shopt -s nullglob
	for arg do

		parse-options() {
			local options="${1#-}"
			while [[ "$options" = *[^[:space:]-]* ]]; do
				case "$options" in
					[rR]* ) isRemovingDirectories=1 ;;
					f* ) isForcing=1 ;;
					[iI]* ) isForcing= ;;
					m* )
						isMoving=1
						arg="${arg/m/}"
						if [[ "$arg" != *[^[:space:]-]* ]]; then return 1; fi
					;;
				esac
				options="${options#?}"
			done
		}

		shift
		case "$arg" in
			-- ) break ;;
			--help )
				[ -z "$isMoving" ] && /usr/bin/rm --help || /usr/bin/mv --help
				return $? ;;
			--recursive ) isRemovingDirectories=1 ;;
			--force ) isForcing=1 ;;
			--interactive=once | --interactive=always ) isForcing= ;;
			-[^[:space:]-]* )
				if ! parse-options "$arg"; then continue; fi
			;;
		esac
		[[ "$arg" = -* ]] && options+=("$arg") && continue
		arg="$(get-absolute-path "$arg" 2>/dev/null || /bin/echo -n "$arg")"
		files+=("$arg")
	done
	for file do
		file="$(get-absolute-path "$file" 2>/dev/null || /bin/echo -n "$file")"
		files+=("$file")
	done
	shopt -u nullglob

	local currentDate=$(/usr/bin/date +%s)  # seconds since the epoch
	# %X = time of file access in seconds since the epoch
	# This time is also updated when using 'rm' and can be used for the check.
	remove-if-stale() {
		local oldFile="$1"
		if (( "${currentDate}" - "$(/usr/bin/stat --printf="%X" "$oldFile")" > "$fileRetentionDuration" )); then
			/usr/bin/rm -r "$oldFile";
		fi
	}

	# create a mapping between files and trash directories
	declare -A filesByTrashDir
	for file in "${files[@]}"; do
		# check unremovable files
		for unremovableFilePath in "${unremovableFilePaths[@]}"; do
			if [ "${file%/}" = "${unremovableFilePath%/}" ]; then
				[ -z "${isForcing}" ] && /bin/echo "Removing “${file}” is not allowed, path is ignored." 1>&2
				continue 2
			fi
		done

		# check trash directory
		if [[ "$file" = *"/$TMP_TRASH" ]]; then
			[ -z "$isForcing" ] && /bin/echo "Won't remove “${file}” which matches the trash suffix “${TMP_TRASH}”."
			continue
		fi

		local mountpoint="$(get-mountpoint "$file" 2>/dev/null)"
		local trashDir="${mountpoint%/}/${TMP_TRASH}"

		if [[ "$file" = "$trashDir"/* ]] \
			&& [ -z "${isForcing}" ] \
			&& read -r -p "“$file” is in the trash, delete it entirely? [y/N] " choice \
			&& [[ "$choice" != [yY] ]]
		then
			continue
		fi

		# delete too old files
		eval "local dirs=($(qfind "${trashDir}/" -mindepth 1 -type d 2>/dev/null))"
		for dir in "${dirs[@]}"; do
			remove-if-stale "$dir" 2>/dev/null
		done

		filesByTrashDir["$trashDir"]+="${file@Q} ";  # will need `eval` later, comparable to a spread operator
	done

	echo-options() {
		for option in "${options[@]}"; do /bin/echo -n "${option@Q} "; done
	}
	echo-files() {
		for file in "${files[@]}"; do /bin/echo "${file@Q}"; done
	}
	echo-filesByTrashDir() {
		for trashDir in "${!filesByTrashDir[@]}"; do /bin/echo "${trashDir@Q} ← ${filesByTrashDir["$trashDir"]}"; done
	}
	if [ "$DEBUG" = 1 ]; then
		/usr/bin/cat <<-END  >&2
			($DEBUG)
			isRemovingDirectories: ${isRemovingDirectories:-0}
			isForcing: ${isForcing:-0}
			currentDate: $currentDate

			== options ==
			$(echo-options)

			== files ==
			$(echo-files)

			== filesByTrashDir ==
			$(echo-filesByTrashDir)
		END
		return 0
	fi

	# warn if users try to remove "important directories"
	# lesson: unsetting the associative array is not seen outside a subshell env `( … )`
	# for some reason, echoing will cause an error that the contents of the associative array could not be used as variable; related to `read`?
	if [ -n "${isRemovingDirectories+y}" ] && [ -z "${isForcing}" ]; then

		# return the filenames (quoted) that coincide with important directories, needs to be `eval`ed
		get-important-dir-matches() {
			local trashDir="$1"
			shift

			for arg do
				filePath="$arg"
				[ ! -d "$filePath" ] || [[ "${filePath%/}/" = "${trashDir}/"* ]] && continue
				for i in {1..3}; do
					filePath="$(/usr/bin/dirname "$filePath")"
				done
				[ "$filePath" = '/' ] || [ -n "${importantDirectories["${arg%/}"]+y}" ] && /bin/echo -n "${arg@Q} "
			done
		}
		
		for trashDir in "${!filesByTrashDir[@]}"; do
			eval "local matches=($(eval "get-important-dir-matches \"\$trashDir\" ${filesByTrashDir["$trashDir"]}"))"
			if (( "${#matches[@]}" > 0 )); then
				if read -r -p "Do you really want to delete "$'\n'"$(for match in "${matches[@]}"; do /bin/echo "“${match}”"; done)"$'\n'"?? [y/N] " choice \
					&& [[ "$choice" != [yY] ]]
				then
					unset 'filesByTrashDir["$trashDir"]'  2>/dev/null
				fi
			fi
		done
	fi

	if [ "$DEBUG" = 2 ]; then
		/usr/bin/cat <<-END  >&2
			($DEBUG)
			== filesByTrashDir ==
			$(echo-filesByTrashDir)
		END
		return 0
	fi

	# cp removed files to an intermediate location or move them to destination
	for trashDir in "${!filesByTrashDir[@]}"; do
		local tmpDir="${trashDir}/.tmp"

		if ! errorMessage="$(/usr/bin/mkdir -p "$tmpDir" 2>&1)" \
			&& [ ! -d "$tmpDir" ]
		then
			if [ -z "$isForcing" ]; then
				/bin/echo "$errorMessage" 1>&2
				unset 'filesByTrashDir["$trashDir"]' 2>/dev/null
			fi
			continue
		fi

		eval "local currentFiles=(${filesByTrashDir["$trashDir"]})"
		local mountpoint="$(--mountpoint-from-trashDir "$trashDir")"
		( for currentFile in "${currentFiles[@]}"; do
			if [[ "${currentFile%/}/" == "${trashDir}/"* ]]; then
				[ -n "${isMoving}" ] && $debugCommand /usr/bin/rm -rf "${currentFile}"
			else
				if [ -z "$isMoving" ]; then
					if ! { [ -d "$currentFile" ] && [ -z "${isRemovingDirectories}" ]; }; then
						local destinationDir="$(unset DEBUG; --mk-destination-dir "$currentFile" "$mountpoint" "$tmpDir" 2>/dev/null)"
						/usr/bin/cp ${DEBUG+"-v"} ${isRemovingDirectories:+"-r"} -a -f -t "${destinationDir}" -- "${currentFile}" 2>/dev/null
					fi
				else
					# avoid the indirection with .tmp
					local destinationDir="$(--mk-destination-dir "$currentFile" "$mountpoint" "$trashDir" 2>/dev/null)"
					${debugCommand} /usr/bin/mv --backup=numbered ${isMoving:+"--no-copy"} "${options[@]}" -t "${destinationDir}" -- "${currentFile}"
				fi
				# update the timestamp (to avoid early removal)
				/usr/bin/touch -c -a "${destinationDir}/$(/usr/bin/basename "$currentFile")" 2>/dev/null
			fi
		done )
		/usr/bin/rmdir "${tmpDir}" 2>/dev/null
	done

	if [ "$DEBUG" = 3 ]; then
		/usr/bin/cat <<-END  >&2
			($DEBUG)
			== filesByTrashDir ==
			$(echo-filesByTrashDir)

			$(for trashDir in "${!filesByTrashDir[@]}"; do
				/bin/echo "== ${trashDir@Q} =="
				/usr/bin/find "${trashDir}/.tmp" -mindepth 1 -printf="“%p”\n" 2>/dev/null
				/bin/echo ""
			done )
		END
		return 0
	fi

	if [ -z "$isMoving" ]; then
		# do the remove action
		eval "$debugCommand /usr/bin/rm \"\${options[@]}\" -- ${filesByTrashDir[@]}"

		# the return status of rm is not clear about which files are deleted, therefore "backup" all of them redundantly
		for trashDir in "${!filesByTrashDir[@]}"; do
			local tmpDir="${trashDir}/.tmp"

			# based on https://stackoverflow.com/questions/1574403/list-all-leaf-subdirectories-in-linux
			eval "local tmpFiles=($(qfind-leaves "$tmpDir" 2>/dev/null))"
			# move trash contents to final destination, if the original file path is gone
			for file in "${tmpFiles[@]}"; do
				local mountpoint="$(--mountpoint-from-trashDir "$trashDir")"
				local realFile="${file/#"${tmpDir}"/"${mountpoint}"}"
				if ! path-exists "$realFile" || [ -n "${DEBUG+y}" ]; then
					${debugCommand} /usr/bin/mv --backup=numbered ${isMoving:+"--no-copy"} -f -t "$(--mk-destination-dir "$file" "${tmpDir}" "$trashDir" 2>/dev/null)" -- "${file}"  2>/dev/null
				fi
			done

			/usr/bin/rm -rf "${tmpDir}" 2>/dev/null
		done
	fi

	shopt -u dotglob
)}

# Pass all the files that you want to recover from the temporary trash (if they are in the trash).
# If you need to recover items ending on `.~number~`, please name them explicitly in separate arguments.
# It only works if the requested file path was passed to remove recently, prior to this call.
# It allows you to recover as many versions as you have removed previously (in reversed order) as long
# as they are not too old (the time interval is set by the top-level variable $fileRetentionDuration).
undo-rm() {(
	TMP_TRASH="${TMP_TRASH:-"$(tmp-trash-dir)"}"
	local errors=0
	local isVerbose
	local isForcing
	local isTesting
	local isDeleting
	local destinationDir
	shopt -s dotglob  # as mentioned here https://unix.stackexchange.com/a/6397/561650

	get-suffix() {
		local fileSuffix="${1#"${1%.~*~}"}"
		[ -z "${fileSuffix}" ] \
		|| /usr/bin/pcre2grep -o0 '^\.~[0-9]+~$' <<<"$fileSuffix" 2>/dev/null
	}
	get-suffix-number() {
		local fileSuffix="${1#"${1%.~*~}"}"
		[ -z "${fileSuffix}" ] && /bin/echo -n '0' \
		|| /usr/bin/pcre2grep -o1 '^\.~([0-9]+)~$' <<<"$fileSuffix" 2>/dev/null
	}

	find-latest-file() {(
		DECLARE="-g" get-trash-path "$1" 1>/dev/null

		if [ "${DEBUG}" = 1 ]; then
			/usr/bin/cat <<-END  >&2
				($DEBUG)
				== $1 ==
				destinationPath: ${destinationPath@Q}
				mountpoint: ${mountpoint@Q}
				trashDir: ${trashDir@Q}
				pathInTrash: ${pathInTrash@Q}

			END
		fi

		# goes through the passed files to find the newest file
		get-latest() {
			local latestTime=0
			local latestFile

			for filePath do
				local fileTime="$(/usr/bin/stat --printf="%X" "$filePath")"
				if (( latestTime <= fileTime )); then  # prefer later files over earlier files in the list
					latestTime="$fileTime"
					latestFile="$filePath"
				fi
			done

			/bin/echo -n "$latestFile"
		}

		# given a suffix-less filename in the trash, find the actual file name with highest suffix.
		# 0 represents infinity (no suffix, highest precedence), 1 is the smallest suffix (lowest precedence)
		find-versions() {
			local filePath="${1}"
			if [ "$filePath" = '/' ]; then
				/bin/echo "Bug, \$pathInTrash is not pointing to a trash location!!" >&2
				return 1
			fi
			if [[ "${trashDir}" = "${filePath%/}" ]]; then
				/bin/echo -n "${filePath@Q} "
				return 0
			fi

			eval "local parents=($(find-versions "$(/usr/bin/dirname "$filePath")"))"
			for parent in "${parents[@]}"; do
				for version in "${parent}/$(/usr/bin/basename "$filePath")"{,.~*~}; do
					if path-exists "$version" \
						&& get-suffix "$version" &>/dev/null
					then
						/bin/echo -n "${version@Q} "
					fi
				done
			done
		}

		if path-exists "$pathInTrash"; then
			local versions=("$pathInTrash")
		else
			eval "local versions=($(find-versions "$pathInTrash"))"
			if (( ${#versions[@]} < 1 )); then
				/bin/echo "undo-rm: “$pathInTrash” not found in trash directory “$trashDir”." 1>&2
				(( errors++ ))
				return 1
			fi
			pathInTrash="$(get-latest "${versions[@]}")"

			if [ "${DEBUG}" = 1 ]; then
				/usr/bin/cat <<-END  >&2
					($DEBUG)
					== versions ==
					$(for version in "${versions[@]@Q}"; do /bin/echo "${version}"; done)
	
					pathInTrash: ${pathInTrash@Q}
				END
			fi
		fi

		/bin/echo -n "${pathInTrash}"
	)}

	get-highest-priority-items() {
		local parentDir="${1}"

		declare -A suffixMap=()
		for item in "${parentDir}/"*; do
			local suffixNumber="$(get-suffix-number "$item")"
			local itemName="$(strip-suffix "$item")"

			# if unset or if the suffix is smaller, update it
			if [ -z "${suffixMap["$itemName"]}" ] \
				|| { (( suffixMap["$itemName"] != 0 )) \
					&& (( suffixNumber > suffixMap["$itemName"] ))
				}
			then
				suffixMap["$itemName"]="$suffixNumber"
			fi
		done

		if [ "$DEBUG" = 3 ]; then
			/usr/bin/cat <<-END >&2
				== ${parentDir@Q} ==
				files:
				$(for item in "${parentDir}/"*; do /bin/echo "  ${item@Q}"; done)
				suffixMap:
				$(for itemName in "${!suffixMap[@]}"; do /bin/echo "  [${itemName@Q}] → ${suffixMap["$itemName"]}"; done)
			END
		fi

		for file in "${!suffixMap[@]}"; do
			local suffixNumber="${suffixMap["$file"]}"
			(( suffixNumber != 0 )) && file+=".~${suffixNumber}~"

			/bin/echo -n "${file@Q} "
		done
	}

	# if the extension matches the general suffix regex, then remove it
	strip-suffix() {
		local filePath="$1"
		/bin/echo -n "${filePath%"$(get-suffix "$filePath")"}"
	}

	strip-suffixes() {
		local targetBasename="$(/usr/bin/basename "$1")"
		local parentDir="$(/usr/bin/dirname "$1")"

		if [[ "${trashDir}/" != "${parentDir}/"* ]]; then
			parentDir="$(strip-suffixes "$parentDir")"
		fi
		/bin/echo -n "${parentDir}/$(strip-suffix "$targetBasename")"
	}

	mv-file-to-destination() {
		local fileInTrash="$1"
		local mountpoint="$(get-mountpoint "$fileInTrash")"
		local trashDir="${mountpoint%/}/${TMP_TRASH}"
		local destinationPath="$(strip-suffixes "$fileInTrash")"
		local targetBasename="$(/usr/bin/basename "$destinationPath")"
		local destination=${destinationDir:+"-t$destinationDir"}


		if [ "$DEBUG" = 5 ]; then
			cat <<-END  >&2
				($DEBUG)
				== ${targetBasename@Q} ==
				fileInTrash: ${fileInTrash@Q}
				mountpoint: ${mountpoint@Q}
				trashDir: ${trashDir@Q}
				targetBasename: ${targetBasename@Q}
				destinationPath: ${destinationPath@Q}
				destinationDir: ${destinationDir@Q}
			END
		fi

		if
			if [ -z "$isDeleting" ]; then
				destination=${destination:-"$(--mk-destination-dir "$destinationPath" "$trashDir" "$mountpoint" 2>/dev/null)/${targetBasename}"}
				! ${DEBUG+"/bin/echo" "preview:"} /usr/bin/mv ${isVerbose:+"-v"} ${isForcing:+"-f"} --backup=numbered "${fileInTrash}" "${destination}"
			else
				! ${DEBUG+"/bin/echo" "preview:"} /usr/bin/rm ${isVerbose:+"-v"} -r ${isForcing:+"-f"} "${fileInTrash}"
			fi
		then (( errors++ )); return 0
		fi

		if [ "$DEBUG" = 5 ]; then /bin/echo "destination: ${destination@Q}" >&2; fi

		# remove directories that have become empty
		parent="$(/usr/bin/dirname "$fileInTrash")"
		until [[ "$trashDir" = "$parent"* ]] \
			|| ! /usr/bin/rmdir "$parent" &>/dev/null
		do
			parent="$(/usr/bin/dirname "$parent")"
		done
		return 0
	}

	# I could not get `find` to use defined functions or array variable
	# So I am making a new recursive function for it
	mv-files-to-destination() {
		for item do
			# recurse into non-empty directories
			if [ -d "$item" ] \
				&&  [ -n "$(/usr/bin/ls -A "$item")" ]
			then
				eval "local highestPriorityFiles=($(get-highest-priority-items "$item"))"

				if [ "$DEBUG" = 4 ]; then
					/usr/bin/cat <<-END >&2
						== ${item@Q} ==
						$(for file in "${highestPriorityFiles[@]@Q}"; do /bin/echo "$file"; done)

					END
				fi

				mv-files-to-destination "${highestPriorityFiles[@]}"
				continue
			fi

			if path-exists "$item"; then
				mv-file-to-destination "${item}"
				continue
			fi
			(( errors++ ))
			/bin/echo "undo-rm: '$item' could not be recovered from (found in the) trash." >&2
		done
	}

	# parse arguments into options and files
	declare -a list=()
	local -i isOptionEnabled=1
	local -i isDestinationDir=0
	for arg do
		if (( isOptionEnabled )); then
			case "$arg" in
				-v ) isVerbose=1; continue ;;
				-f ) isForcing=1; continue ;;
				--test ) isTesting=1; continue ;;
				-t ) isDestinationDir=1; continue ;;
				"" | -h | --help ) cat <<-"END" >&2
						usage: undo-rm <options|files> [-- <files>]

						options:
							-h, --help : prints this message
							--test     : dry run, testing. Does not move files from trash.
							-t         : Indicates that the next file is used as destination directory.
							-v         : passes the “verbose” flag to the 'mv' operation. Shows what file action happens.
							-f         : Passes the “force” flag to 'mv'.
							--delete   : Instead of moving the files to the destination, it will delete them entirely.
							--         : Delimits the options. All arguments after it are interpreted as filenames.

						files:
							File pathes (relative or absolute) as individual arguments.
							It can point to the path that was previously 'rm'-ed or directly pointing inside the trash.
							There is no difference in referencing a file inside the trash or via the original path.
						
						Use 'get-trash-dir <path>' to find the closest trash location.
						Trash directories are created at the root of partitions and files will be found in the closest
						trash directory (to avoid moving files between filesystems).

						Keep in mind that trash files will be cleant up when they reach a specific age.
						The cleanup is triggered by new 'rm' calls.
						This facility is not supposed to be a backup functionality. It can only temporarily recover
						files removed with (the modified) 'rm' but not for example files deleted with 'rsync'.
					END
					return 1 ;;
				--delete ) isDeleting=1; continue ;;
				-- ) isOptionEnabled=0; continue ;;
				-* ) /bin/echo "undo-rm: unsupported option '$arg'. Try '-h' or '--help' for help." 1>&2; return 1 ;;
			esac
		fi
		if (( isDestinationDir )); then
			destinationDir="$(get-absolute-path "$arg")"
			isDestinationDir=0
		else
			if fileInTrash="$(find-latest-file "$arg")"; then
				files+=("$fileInTrash")
			fi
		fi
	done

	if [[ "$DEBUG" = [2345] ]]; then
		/usr/bin/cat <<-END >&2
			($DEBUG)
			== files ==
			${files[@]@Q}
		END
		[ "$DEBUG" = 2 ] && return 0
	fi

	if (( ${#files[@]} < 1 )); then
		return 1;
	fi

	if (( isTesting )) && (( isVerbose )); then DEBUG=0; fi
	mv-files-to-destination "${files[@]}"

	shopt -u dotglob
	return $errors
)}
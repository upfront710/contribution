#!/bin/bash

source launch_diff_variables.sh

EXTPROJECTS=()
PACKAGE_MASTER=true
RUN_MASTER=true
PACKAGE_PULL=true
RUN_PULL=true
RUN_REPORTS=true
USE_CUSTOM_BASE_CONFIG=false
CUSTOM_BASE_CONFIG=""
USE_CUSTOM_PATCH_CONFIG=false
CUSTOM_PATCH_CONFIG=""
USE_CUSTOM_MASTER=false
CUSTOM_MASTER=""
PATCH_ONLY=false

if [ -z "$1" ]; then
	echo "No parameter supplied!"
	echo "      Either supply the PR branch to work with or 'clean'."
	echo ""
	exit 1
fi

if [ "$1" == "clean" ] || [ "$1" == "-clean" ]; then
	echo "Cleaning..."

	cd $CHECKSTYLE_DIR
	mvn --batch-mode clean
	cd $TESTER_DIR
	rm -rf $SITE_SAVE_MASTER_DIR
	rm -rf $SITE_SAVE_PULL_DIR
	rm -rf $FINAL_RESULTS_DIR/*
	exit 0
fi

function parse_arguments {
	SKIP=true

	while [[ $# > 0 ]] ; do
		if ! $SKIP ; then
			case "$1" in
			-skip)
				case "$2" in
				package_master)
					PACKAGE_MASTER=false
					;;
				master)
					PACKAGE_MASTER=false
					RUN_MASTER=false
					;;
				package_pull)
					PACKAGE_PULL=false
					;;
				pull)
					PACKAGE_PULL=false
					RUN_PULL=false
					;;
				reports)
					RUN_REPORTS=false
					;;
				*)
					echo "Unknown option: $2"
					exit 1
					;;
				esac
				shift
				;;
			-master)
				USE_CUSTOM_MASTER=true
				CUSTOM_MASTER=$2
				shift
				;;
			-config)
				USE_CUSTOM_BASE_CONFIG=true
				USE_CUSTOM_PATCH_CONFIG=true
				CUSTOM_BASE_CONFIG=$2
				CUSTOM_PATCH_CONFIG=$2
				shift
				;;
			-baseConfig)
				USE_CUSTOM_BASE_CONFIG=true
				CUSTOM_BASE_CONFIG=$2
				shift
				;;
			-patchConfig)
				USE_CUSTOM_PATCH_CONFIG=true
				CUSTOM_PATCH_CONFIG=$2
				shift
				;;
			-output)
				FINAL_RESULTS_DIR=$2
				shift
				;;
			-patchOnly)
				PATCH_ONLY=true
				PACKAGE_MASTER=false
				RUN_MASTER=false
				;;
			*)
				echo "Unknown option: $1"
				exit 1
				;;
			esac
		else
			SKIP=false
		fi
		shift
	done
}

function mvn_package {
	echo "mvn --batch-mode -Pno-validations clean package -Passembly"
	mvn --batch-mode -Pno-validations clean package -Passembly

	if [ $? -ne 0 ]; then
		echo "Maven Package Failed!"
		exit 1
	fi
}

function launch {
		echo "Verifying Launch config ..."

		CS_VERSION="grep 'SNAPSHOT</version>' $CHECKSTYLE_DIR/pom.xml | tail -1 | cut -d '>' -f2 | cut -d '<' -f1"
		CS_VERSION="$(eval $CS_VERSION)"

		echo "Config version: $CS_VERSION"

		CS_JAR=$CHECKSTYLE_DIR/target/checkstyle-$CS_VERSION-all.jar
		if [ ! -f $CS_JAR ] ; then
			echo "Failed to find Checkstyle JAR: $CS_JAR"
			exit 1
		fi

		if [ ! -d "$1" ]; then
			mkdir $1
		fi

		while read line ; do
			[[ "$line" == \#* ]] && continue # Skip lines with comments
			[[ -z "$line" ]] && continue     # Skip empty lines
			
			REPO_NAME=`echo $line | cut -d '|' -f 1`
			REPO_TYPE=`echo $line | cut -d '|' -f 2`
			REPO_URL=` echo $line | cut -d '|' -f 3`
			COMMIT_ID=`echo $line | cut -d '|' -f 4`
			EXCLUDES=` echo $line | cut -d '|' -f 5`
			
			echo "Running Launch on $REPO_NAME ..."
			
			if [ ! -d "$REPOSITORIES_DIR" ]; then
				mkdir $REPOSITORIES_DIR
			fi
			CURRENT_REPO_DIR=""
			
			if [ "$REPO_TYPE" == "git" ]; then
				GITPATH=$REPOSITORIES_DIR/$REPO_NAME
				
				if [ ! -d "$GITPATH" ]; then
					echo "Cloning $REPO_TYPE repository '${REPO_NAME}' ..."
					git clone $REPO_URL $GITPATH
					echo -e "Cloning $REPO_TYPE repository '$REPO_NAME' - completed"
				fi
				if [ "$COMMIT_ID" != "" ] && [ "$COMMIT_ID" != "master" ]; then
					echo "Reseting $REPO_TYPE sources to commit '$COMMIT_ID'"
					cd $GITPATH
					if $CONTACTSERVER ; then
						git fetch origin
					fi
					git reset --hard $COMMIT_ID
					git clean -f -d
					cd -
				else
					echo "Reseting GIT $REPO_TYPE sources to head"
					cd $GITPATH
					if $CONTACTSERVER ; then
						git fetch origin
					fi
					git reset --hard origin/master
					git clean -f -d
					cd -
				fi

				CURRENT_REPO_DIR=$GITPATH
			elif [ "$REPO_TYPE" == "hg" ]; then
				HGPATH=$REPOSITORIES_DIR/$REPO_NAME

				if [ ! -d "$HGPATH" ]; then
					echo "Cloning $REPO_TYPE repository '${REPO_NAME}' ..."
					hg clone $REPO_URL $HGPATH
					echo -e "Cloning $REPO_TYPE repository '$REPO_NAME' - completed"
				fi
				if [ "$COMMIT_ID" != "" ] && [ "$COMMIT_ID" != "master" ]; then
					echo "Reseting HG $REPO_TYPE sources to commit '$COMMIT_ID'"
					cd $HGPATH
					hg up $COMMIT_ID
					cd -
				fi

				CURRENT_REPO_DIR=$HGPATH
			else
				echo "Unknown RepoType: $REPO_TYPE"
				exit 1
			fi

			if [ ! -d "$1/$REPO_NAME" ]; then
				mkdir $1/$REPO_NAME
			fi

			echo "Running Checkstyle with config $2 ... with excludes $EXCLUDES"

			if [ "$EXCLUDES" == "" ]; then
				echo "java -Xmx3024m -jar $CS_JAR -c $2 -f xml -o $1/$REPO_NAME/results.xml $CURRENT_REPO_DIR --executeIgnoredModules"
				java -Xmx3024m -jar $CS_JAR -c $2 -f xml -o $1/$REPO_NAME/results.xml $CURRENT_REPO_DIR --executeIgnoredModules
			else
				echo "java -Xmx3024m -jar $CS_JAR -c $2 -f xml -o $1/$REPO_NAME/results.xml -x '$EXCLUDES' $CURRENT_REPO_DIR --executeIgnoredModules"
				java -Xmx3024m -jar $CS_JAR -c $2 -f xml -o $1/$REPO_NAME/results.xml -x "$EXCLUDES" $CURRENT_REPO_DIR --executeIgnoredModules
			fi

			if [ "$?" == "-2" ] || [ "$?" == "-1" ];
			then
				echo "Checkstyle failed"
				exit 1
			else
				echo "Running Checkstyle - finished"
			fi

			if ! containsElement "$REPO_NAME" "${EXTPROJECTS[@]}" ; then
				EXTPROJECTS+=($REPO_NAME)
			fi

			echo "Running Launch on $REPO_NAME - completed"
		done < $TESTER_DIR/projects-to-test-on.properties
}

function containsElement {
	local e
	for e in "${@:2}";
	do
		[[ "$e" == "$1" ]] && return 0;
	done
	return 1
}

# ============================================================
# ============================================================
# ============================================================

parse_arguments "$@"

echo "Testing Checkstyle Starting"

if $CONTACTSERVER ; then
	echo "with server updates enabled"
fi

if $PACKAGE_MASTER ; then
	cd $CHECKSTYLE_DIR

	if $USE_CUSTOM_MASTER ; then
		git fetch $PULL_REMOTE

		if [ ! `git rev-parse --verify $PULL_REMOTE/$CUSTOM_MASTER` ] ;
		then
			echo "Branch $PULL_REMOTE/$CUSTOM_MASTER doesn't exist"
			exit 1
		fi

		git checkout $PULL_REMOTE/$CUSTOM_MASTER
	else
		if $CONTACTSERVER ; then
			git fetch origin
		fi

		git reset --hard HEAD
		git checkout origin/master
	fi

	git clean -f -d

	echo "Packaging Master"

	mvn_package
else
	echo "Skipping Install Master"
fi

if $RUN_MASTER ; then
	echo "Starting Master Launcher"

	rm -rf $SITE_SAVE_MASTER_DIR

	BASE_CONFIG=""
	if $USE_CUSTOM_BASE_CONFIG ; then
		BASE_CONFIG=$CUSTOM_BASE_CONFIG
	else
		BASE_CONFIG="$TESTER_DIR/my_checks_$REPO_NAME.xml"

		if [ ! -f $BASE_CONFIG ] ; then
			BASE_CONFIG="$TESTER_DIR/my_checks.xml"
		fi
	fi

	launch $SITE_SAVE_MASTER_DIR $BASE_CONFIG
else
	echo "Skipping Launch Master"
fi

if $PACKAGE_PULL ; then
	cd $CHECKSTYLE_DIR

	echo "Checking out and Packaging PR $1"

	git fetch $PULL_REMOTE

	if [ ! `git rev-parse --verify $PULL_REMOTE/$1` ] ;
	then
		echo "Branch $PULL_REMOTE/$1 doesn't exist"
		exit 1
	fi

	git checkout $PULL_REMOTE/$1
	git clean -f -d

	mvn_package
else
	echo "Skipping Install PR $1"
fi

if $RUN_PULL ; then
	echo "Starting PR $1 Launcher"

	rm -rf $SITE_SAVE_PULL_DIR

	PATCH_CONFIG=""
	if $USE_CUSTOM_PATCH_CONFIG ; then
		PATCH_CONFIG=$CUSTOM_PATCH_CONFIG
	else
		PATCH_CONFIG="$TESTER_DIR/my_checks_$REPO_NAME.xml"

		if [ ! -f $PATCH_CONFIG ] ; then
			PATCH_CONFIG="$TESTER_DIR/my_checks.xml"
		fi
	fi

	launch $SITE_SAVE_PULL_DIR $PATCH_CONFIG
else
	echo "Skipping Launch PR $1"
fi

if $RUN_REPORTS ; then
	if ! $RUN_MASTER && ! $RUN_PULL ; then
		echo "Figuring out Reports to run"

		while read line ; do
			[[ "$line" == \#* ]] && continue # Skip lines with comments
			[[ -z "$line" ]] && continue     # Skip empty lines
			
			REPO_NAME=`echo $line | cut -d '|' -f 1`

			EXTPROJECTS+=($REPO_NAME)
		done < $TESTER_DIR/projects-to-test-on.properties
	fi

	echo "Starting all Reports"

	if [ ! -d "$FINAL_RESULTS_DIR" ]; then
		mkdir $FINAL_RESULTS_DIR
	else
		rm -rf $FINAL_RESULTS_DIR/*
	fi

	OUTPUT_FILE="$FINAL_RESULTS_DIR/index.html"

	if [ -f $OUTPUT_FILE ] ; then
		rm $OUTPUT_FILE
	fi
	echo "<html><head>" >> $OUTPUT_FILE
	echo "<link rel='icon' href='https://checkstyle.org/images/favicon.png' type='image/x-icon' />" >> $OUTPUT_FILE
	echo "<title>Checkstyle Tester Report Diff Summary</title>" >> $OUTPUT_FILE
	echo "</head><body>" >> $OUTPUT_FILE
	echo "<h3><span style=\"color: #ff0000;\">" >> $OUTPUT_FILE
	echo "<strong>WARNING: Excludes are ignored by diff.groovy.</strong>" >> $OUTPUT_FILE
	echo "</span></h3>" >> $OUTPUT_FILE

	if $RUN_MASTER ; then
		if $USE_CUSTOM_MASTER ; then
			REMOTE="$PULL_REMOTE/$CUSTOM_MASTER"
		else
			REMOTE="origin/master"
		fi

		cd $CHECKSTYLE_DIR
		HASH=$(git rev-parse $REMOTE)
		MSG=$(git log $REMOTE -1 --pretty=%B)

		echo "<h6>" >> $OUTPUT_FILE
		echo "Base branch: $REMOTE<br />" >> $OUTPUT_FILE
		echo "Base branch last commit SHA: $HASH<br />" >> $OUTPUT_FILE
		echo "Base branch last commit message: $MSG<br />" >> $OUTPUT_FILE
		echo "</h6>" >> $OUTPUT_FILE
	fi
	if $RUN_PULL ; then
		REMOTE="$PULL_REMOTE/$1"

		cd $CHECKSTYLE_DIR
		HASH=$(git rev-parse $REMOTE)
		MSG=$(git log $REMOTE -1 --pretty=%B)

		echo "<h6>" >> $OUTPUT_FILE
		echo "Patch branch: $REMOTE<br />" >> $OUTPUT_FILE
		echo "Patch branch last commit SHA: $HASH<br />" >> $OUTPUT_FILE
		echo "Patch branch last commit message: $MSG<br />" >> $OUTPUT_FILE
		echo "</h6>" >> $OUTPUT_FILE
	fi
	echo "Tested projects: ${#EXTPROJECTS[@]}" >> $OUTPUT_FILE
	echo "<br /><br /><br />" >> $OUTPUT_FILE

	for extp in "${EXTPROJECTS[@]}"
	do
		if [ ! -d "$FINAL_RESULTS_DIR/$extp" ]; then
			BASE_CONFIG=""
			PATCH_CONFIG=""
			if $USE_CUSTOM_BASE_CONFIG ; then
				if [[ "$CUSTOM_BASE_CONFIG" = /* ]]; then
					BASE_CONFIG=$CUSTOM_BASE_CONFIG
				else
					BASE_CONFIG="$TESTER_DIR/$CUSTOM_BASE_CONFIG"
				fi
			else
				BASE_CONFIG="$TESTER_DIR/my_checks_$extp.xml"

				if [ ! -f $BASE_CONFIG ] ; then
					BASE_CONFIG="$TESTER_DIR/my_checks.xml"
				fi
			fi
			if $USE_CUSTOM_PATCH_CONFIG ; then
				if [[ "$CUSTOM_PATCH_CONFIG" = /* ]]; then
					PATCH_CONFIG=$CUSTOM_PATCH_CONFIG
				else
					PATCH_CONFIG="$TESTER_DIR/$CUSTOM_PATCH_CONFIG"
				fi
			else
				PATCH_CONFIG="$TESTER_DIR/my_checks_$extp.xml"

				if [ ! -f $PATCH_CONFIG ] ; then
					PATCH_CONFIG="$TESTER_DIR/my_checks.xml"
				fi
			fi

			if $PATCH_ONLY ; then
				echo "java -jar $DIFF_JAR --patchReport $SITE_SAVE_PULL_DIR/$extp/results.xml --output $FINAL_RESULTS_DIR/$extp --patchConfig $PATCH_CONFIG --refFiles $REPOSITORIES_DIR/$extp"

				java -jar $DIFF_JAR --patchReport $SITE_SAVE_PULL_DIR/$extp/results.xml --output $FINAL_RESULTS_DIR/$extp --patchConfig $PATCH_CONFIG --refFiles $REPOSITORIES_DIR/$extp
			else
				echo "java -jar $DIFF_JAR --baseReport $SITE_SAVE_MASTER_DIR/$extp/results.xml --patchReport $SITE_SAVE_PULL_DIR/$extp/results.xml --output $FINAL_RESULTS_DIR/$extp --baseConfig $BASE_CONFIG --patchConfig $PATCH_CONFIG --refFiles $REPOSITORIES_DIR/$extp"

				java -jar $DIFF_JAR --baseReport $SITE_SAVE_MASTER_DIR/$extp/results.xml --patchReport $SITE_SAVE_PULL_DIR/$extp/results.xml --output $FINAL_RESULTS_DIR/$extp --baseConfig $BASE_CONFIG --patchConfig $PATCH_CONFIG --refFiles $REPOSITORIES_DIR/$extp
			fi

			if [ "$?" != "0" ]
			then
				echo "patch-diff-report-tool failed on $extp"
				exit 1
			fi
		else
			echo "Skipping patch-diff-report-tool for $extp"
		fi

		total=($(grep -Eo 'totalDiff">[0-9]+' $FINAL_RESULTS_DIR/$extp/index.html | grep -Eo '[0-9]+'))

		echo "<a href='$extp/index.html'>$extp</a>" >> $OUTPUT_FILE
		if [ ${#total[@]} != "0" ] ; then
			if [ ${total[0]} -ne 0 ] ; then
				echo " (${total[0]})" >> $OUTPUT_FILE
			fi
		fi
		echo "<br />" >> $OUTPUT_FILE
	done

	echo "</body></html>" >> $OUTPUT_FILE
fi

echo "Complete"

exit 0

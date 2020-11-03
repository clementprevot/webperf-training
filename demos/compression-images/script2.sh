#!/usr/bin/env bash



###############################################################################
#
# Intro:
# 	Automatically find the ideal JPEG quality setting for a JPEG image by
#	calculating the output images dissimilarity from the input JPEG. This
# 	frees us from having to rely on the unstandardized quality integer.
#
# Installation instructions:
#	Place this script anywhere in your $PATH. Requires Bash >= 4.x
#
# Required tools:
#	* dssim - https://github.com/pornel/dssim
#	* jpegoptim - https://github.com/tjko/jpegoptim
#	* mozjpeg - https://github.com/mozilla/mozjpeg
#
# CLI usage example:
# 	cjpeg-dssim jpegoptim /path/to/input-image.jpg
#
# Supported encoders:
#	* jpegoptim
#	* mozjpeg
#
# Changes from original version:
#   * more configuration options
#   * output quality chosen at the end
#   * output quality/DSSIM at each iteration
#   * better binary search (summand/subtrahend is not halfed unconditionally)
###############################################################################



###############################################################################
# SANITY CHECKS
###############################################################################

# Set locales to C (raw uninterpreted byte sequence) to avoid illegal byte sequence errors and invalid number errors
export LANG=C LC_NUMERIC=C LC_COLLATE=C

# Check for proper input parameters
# Filename and selected JPEG compressor should both be set
if [ -z $1 ] || [ -z $2 ]; then
	echo "Please select a JPEG compression method and input JPEG"
elif [ -n $1 ] && [ -n $2 ]; then
	JPEG_COMPRESSION_SELECTION="$1"
	INPUTFILE="$2"
else
	exit 1
fi

# Path and filename retrieval to save the output image
CLEANFILENAME=${INPUTFILE%.jp*g}
FILEEXTENSION=${INPUTFILE##*.}
CLEANPATH="${INPUTFILE%/*}"
# If the JPEG is in the same direcctory, empty the path variable
# Or if it is set, make sure the path has a trailing slash
if [ "$CLEANPATH" == "$INPUTFILE" ]; then
	CLEANPATH=""
else
	CLEANPATH="$CLEANPATH/"
fi



###############################################################################
# CONFIGURABLE RUNTIME VARIABLES
###############################################################################

# Initial JPEG quality and summand/subtrahend settings to start from
INITIAL_JPEG_QUALITY="85"
JPEG_QUALITY_SUMMAND_SUBTRAHEND="25"
MAX_ITERATIONS=10

# The dissimilarity range in which we accept a recompressed JPEG image
DSSIM_LOWER_BOUND="0.008"
DSSIM_UPPER_BOUND="0.010"

# How should the output image name be amended - Leave empty to overwrite
OUTPUTFILESUFFIX="_dssim"

JPEGOPTIM_PATH="jpegoptim"
MOZJPEG_PATH="mozjpeg"
DSSIM_PATH="dssim"

###############################################################################
# MAIN PROGRAM
###############################################################################

main () {
	define_encoder_toolbelt
	local -i __current_jpeg_quality=$(optimize_quality_level ${INITIAL_JPEG_QUALITY} ${JPEG_QUALITY_SUMMAND_SUBTRAHEND})
	echo "Selected JPEG quality: ${__current_jpeg_quality}"
	$(eval ${JPEG_COMPRESSION_COMMAND} > "${CLEANPATH}${CLEANFILENAME##*/}${OUTPUTFILESUFFIX}".${FILEEXTENSION});
}



###############################################################################
# FUNCTIONS
###############################################################################

function define_encoder_toolbelt () {
	# Define our toolbelt of JPEG compression commands and make them selectable from the CLI
	case ${JPEG_COMPRESSION_SELECTION} in
		"jpegoptim") JPEG_COMPRESSION_COMMAND="${JPEGOPTIM_PATH} -q -p -f --max=\${__current_jpeg_quality} --strip-all --all-progressive --stdout \${INPUTFILE}";;
		"mozjpeg") JPEG_COMPRESSION_COMMAND="${MOZJPEG_PATH} -quality \${__current_jpeg_quality} -dct float \${INPUTFILE}";;
	   *) echo "Supported JPEG compression methods: jpegoptim | mozjpeg"; exit 1;;
	esac
}

function optimize_quality_level () {
	local -i __current_jpeg_quality=$1
	local -i __current_jpeg_quality_summand_subtrahend=$2
	local -i __iteration_counter="0"
	local __current_dssim_score="0"
	local __arithmetic_operator="-"
	# While the result of the current run is either too similar (ecouraging stronger compression) or too different (already too many artifacts visible), run the compression again while homing in on a proper quality setting for the current encoder
	while ( (( $(echo "${__current_dssim_score} >= ${DSSIM_UPPER_BOUND}" | bc -l) )) || (( $(echo "${__current_dssim_score} < ${DSSIM_LOWER_BOUND}" | bc -l) )) ) && (( ${__iteration_counter}<${MAX_ITERATIONS} )); do
		# Retrieve the current dissimilarity score
		__current_dssim_score=$(calculate_dissimilarity "${__current_jpeg_quality}")
		echo -n "iteration ${__iteration_counter} || dssim: ${__current_dssim_score} quality: ${__current_jpeg_quality}" 1>&2
		# Define if we need to add or substract from the current JPEG quality (DRY)
		local __last_arithmetic_operator="${__arithmetic_operator}"
		if (( $(echo "${__current_dssim_score} < ${DSSIM_LOWER_BOUND}" | bc -l) )); then
			local __arithmetic_operator="-"
		elif (( $(echo "${__current_dssim_score} >= ${DSSIM_UPPER_BOUND}" | bc -l) )); then
			local __arithmetic_operator="+"
		else
			echo 1>&2
			echo ${__current_jpeg_quality}
			return
		fi
		# Binary-search-esque approach to home in on an acceptable JPEG quality by halfing the summand/subtrahend
		# halfing is only done if doing the calculation produces a quality value that requires going back to get to the target
		# e.g. q=50 should be higher -> +20 -> q=70 should be lower -> summand/subtrahend is halfed
		#      q=50 should be higher -> +10 -> q=60 should be higher -> summand/subtrahend is *not* halfed
		if [ "${__last_arithmetic_operator}" != "${__arithmetic_operator}" ]; then
			__current_jpeg_quality_summand_subtrahend=$(echo "scale=0; ${__current_jpeg_quality_summand_subtrahend}/2" | bc -l)
			if (( ${__current_jpeg_quality_summand_subtrahend}==0 )); then
				__current_jpeg_quality_summand_subtrahend="1"
			fi
		fi
		echo " step: ${__arithmetic_operator}${__current_jpeg_quality_summand_subtrahend}" 1>&2
		# Set the JPEG quality to the newly calculated value
		__current_jpeg_quality=$(echo "scale=0; ${__current_jpeg_quality}${__arithmetic_operator}${__current_jpeg_quality_summand_subtrahend}" | bc -l)
		(( __iteration_counter++ ))
	done
	echo ${__current_jpeg_quality}
}

function calculate_dissimilarity () {
	local __current_jpeg_quality=$1
	# Convert the original JPEG to PNG for DSSIM comparison
	# Also base64 it so we can safely store its result in a variable without needing to write the file to disk
	local __original_image_png_base64=$(convert "${INPUTFILE}" png:- | base64)
	# Run the JPEG compressor, pipe its output to convert, create a PNG from the newly compressed JPEG and hand it to DSSIM for comparison - all without creating a file on disk to increase runtime performance
	local __current_dissimilarity=$(eval ${JPEG_COMPRESSION_COMMAND} | convert - png:- | ${DSSIM_PATH} <(echo "${__original_image_png_base64}" | base64 --decode) /dev/stdin | awk '{print $1}')
	echo ${__current_dissimilarity}
}

main

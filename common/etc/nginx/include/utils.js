/*
 *  Copyright 2023 F5, Inc.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

/**
 * @module utils
 * @alias Utils
 */

const fs = require('fs');

/**
 * The current moment as a timestamp. This timestamp will be used across
 * functions in order for there to be no variations in signatures.
 *
 * This constant exists solely for signature-timestamp stability and is stable
 * per njs VM context, not per wall-clock moment. Never use it for freshness
 * or expiry decisions: if module scope persists across requests (e.g. the
 * QuickJS engine with context reuse), it freezes at context-creation time.
 *
 * It lives here rather than in awscredentials.js so that awssig4.js can read
 * it without importing awscredentials.js - njs cannot resolve circular
 * imports, and awscredentials.js needs to import awssig4.js to sign its STS
 * requests.
 * @type {Date}
 */
const NOW = new Date();

/**
 * Flag indicating debug mode operation. If true, additional information
 * about signature generation will be logged.
 * @type {boolean}
 */
const DEBUG = parseBoolean(process.env['DEBUG']);

/**
 * Suffix appended to a setting's environment variable name to form the name of
 * the variable that instead points at a file holding the setting's value. This
 * is the convention used by container secret stores, which mount each secret
 * as a read-only file rather than exposing it in the environment.
 * @see {@link https://docs.docker.com/engine/swarm/secrets/ | Manage sensitive data with Docker secrets}
 * @type {string}
 */
const ENV_VAR_FILE_SUFFIX = '_FILE';

/**
 * Values already read from the files named by '<setting>_FILE' environment
 * variables, keyed by setting name. Reading once means the several credential
 * lookups made while serving a single request share one file read. As with the
 * NOW constant above, module scope lasts as long as the njs VM context rather
 * than the worker process, so this is not a cross-request cache.
 * @type {Object.<string, string>}
 */
let envVarFileCache = {};


/**
 * Checks to see if all the elements of the passed array are present as keys
 * in the running process' environment variables. Alternatively, if a single
 * string is passed, it will check for the presence of that string.
 * @param envVars {Array<String>|string} array of expected keys or single expected key
 * @returns {boolean} true if all keys are set as environment variables
 */
function areAllEnvVarsSet(envVars) {
    if (envVars instanceof Array) {
        const envVarsLen = envVars.length;
        for (let i = 0; i < envVarsLen; i++) {
            if (!process.env[envVars[i]]) {
                return false;
            }
        }
        return true;
    }
    return envVars in process.env;
}

/**
 * Reads a configuration setting that is supplied either directly in the
 * environment variable 'name' or indirectly through a file whose path is held
 * in the companion '<name>_FILE' variable. The direct variable wins when both
 * are set; the container entrypoint rejects that combination outright, but the
 * systemd install has no equivalent check.
 *
 * File contents are trimmed for the same reason the web identity and EKS pod
 * identity token files are: a secret written with a text editor almost always
 * ends in a newline, and a credential with a trailing newline invalidates
 * every signature the gateway produces.
 *
 * @param name {string} name of the environment variable holding the setting
 * @returns {string|undefined} the setting's value, or undefined when neither
 *          the variable nor its companion file variable holds a value
 */
function readEnvVarOrFile(name) {
    const direct = process.env[name];
    if (direct) {
        return direct;
    }

    const fileVarName = name + ENV_VAR_FILE_SUFFIX;
    const path = process.env[fileVarName];
    if (!path) {
        return undefined;
    }

    if (name in envVarFileCache) {
        return envVarFileCache[name];
    }

    let contents;
    try {
        contents = fs.readFileSync(path).toString().trim();
    } catch (e) {
        /* Name the setting and the path but never the contents - this error
           reaches the NGINX error log. */
        throw `Could not read ${fileVarName} (${path}): ${e}`;
    }

    if (contents.length === 0) {
        /* An empty value satisfies every presence check downstream and then
           fails at the S3 origin as an opaque 403, so reject it here where the
           cause is still obvious. */
        throw `${fileVarName} refers to an empty file (${path})`;
    }

    envVarFileCache[name] = contents;
    return contents;
}

/**
 * Discards the values memoized by readEnvVarOrFile so that a subsequent read
 * goes back to the file.
 *
 * @private
 */
function resetEnvVarFileCache() {
    envVarFileCache = {};
}

/**
 * Parses a string delimited by semicolons into an array of values
 * @param string {string|null} value representing a array of strings
 * @returns {Array<String>} a list of values
 */
function parseArray(string) {
    if (string == null || !string || string === ';') {
        return [];
    }

    // Exclude trailing delimiter
    if (string.endsWith(';')) {
        return string.substr(0, string.length - 1).split(';');
    }

    return string.split(';')
}

/**
 * Parses a string to and returns a boolean value based on its value. If the
 * string can't be parsed, this method returns false.
 *
 * @param string {*} value representing a boolean
 * @returns {boolean} boolean value of string
 */
function parseBoolean(string) {
    switch(string) {
        case "TRUE":
        case "true":
        case "True":
        case "YES":
        case "yes":
        case "Yes":
        case "1":
            return true;
        default:
            return false;
    }
}

/**
 * Outputs a log message to the request logger if debug messages are enabled.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @param msg {string} message to log
 */
function debug_log(r, msg) {
    if (DEBUG && "log" in r) {
        r.log(msg);
    }
}

/**
 * Pads the supplied number with leading zeros.
 *
 * @param num {number|string} number to pad
 * @param size number of leading zeros to pad
 * @returns {string} a string with leading zeros
 * @private
 */
function padWithLeadingZeros(num, size) {
    const s = "0" + num;
    return s.substr(s.length-size);
}

/**
 * Creates a string in the ISO601 date format (YYYYMMDD'T'HHMMSS'Z') based on
 * the supplied timestamp and date. The date is not extracted from the timestamp
 * because that operation is already done once during the signing process.
 *
 * @param timestamp {Date} timestamp to extract date from
 * @param eightDigitDate {string} 'YYYYMMDD' format date string that was already extracted from timestamp
 * @returns {string} string in the format of YYYYMMDD'T'HHMMSS'Z'
 * @private
 */
function getAmzDatetime(timestamp, eightDigitDate) {
    const hours = timestamp.getUTCHours();
    const minutes = timestamp.getUTCMinutes();
    const seconds = timestamp.getUTCSeconds();

    return ''.concat(
        eightDigitDate,
        'T', padWithLeadingZeros(hours, 2),
        padWithLeadingZeros(minutes, 2),
        padWithLeadingZeros(seconds, 2),
        'Z');
}

/**
 * Formats a timestamp into a date string in the format 'YYYYMMDD'.
 *
 * @param timestamp {Date} timestamp
 * @returns {string} a formatted date string based on the input timestamp
 * @private
 */
function getEightDigitDate(timestamp) {
    const year = timestamp.getUTCFullYear();
    const month = timestamp.getUTCMonth() + 1;
    const day = timestamp.getUTCDate();

    return ''.concat(padWithLeadingZeros(year, 4),
        padWithLeadingZeros(month,2),
        padWithLeadingZeros(day,2));
}

/**
 * Get the timestamp used across functions in order for there to be no
 * variations in signatures.
 *
 * The returned value is the module-level NOW constant, which is stable per
 * njs VM context rather than the current wall-clock moment. Never use it for
 * freshness or expiry decisions - see the note on NOW.
 *
 * @returns {Date} signature-stable timestamp for the current VM context
 */
function Now() {
    return NOW;
}


/**
 * Checks to see if the given environment variable is present. If not, an error
 * is thrown.
 * @param envVarName {string} environment variable to check for
 * @private
 */
function requireEnvVar(envVarName) {
    const isSet = envVarName in process.env;

    if (!isSet) {
        throw('Required environment variable ' + envVarName + ' is missing');
    }
}

export default {
    Now,
    areAllEnvVarsSet,
    debug_log,
    debugEnabled: DEBUG,
    getAmzDatetime,
    getEightDigitDate,
    padWithLeadingZeros,
    parseArray,
    parseBoolean,
    readEnvVarOrFile,
    requireEnvVar,
    // These functions do not need to be exposed, but they are exposed so that
    // unit tests can run against them.
    resetEnvVarFileCache
}

#!env njs

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

import utils from "include/utils.js";

const fs = require('fs');

function testParseBoolean() {
    printHeader('testParseBoolean');

    function testCanonicalTable() {
        console.log('  ## testCanonicalTable');
        // The exported table is the contract the shell helpers
        // (gateway_env_lib.sh) and test_entrypoint_boolean_validation.sh
        // pin against - a change here must be made on both sides.
        const expectedTrue = ['true', 'yes', '1'];
        const expectedFalse = ['false', 'no', '0'];
        if (utils.BOOLEAN_TRUE_VALUES.join(',') !== expectedTrue.join(',')) {
            throw 'Unexpected BOOLEAN_TRUE_VALUES\n' +
                `Actual:   [${utils.BOOLEAN_TRUE_VALUES.join(',')}]\n` +
                `Expected: [${expectedTrue.join(',')}]`;
        }
        if (utils.BOOLEAN_FALSE_VALUES.join(',') !== expectedFalse.join(',')) {
            throw 'Unexpected BOOLEAN_FALSE_VALUES\n' +
                `Actual:   [${utils.BOOLEAN_FALSE_VALUES.join(',')}]\n` +
                `Expected: [${expectedFalse.join(',')}]`;
        }
    }
    function testTrueSpellings() {
        console.log('  ## testTrueSpellings');
        const spellings = ['true', 'TRUE', 'True', 'TrUe',
            'yes', 'YES', 'Yes', 'yEs', '1'];
        spellings.forEach((value) => {
            if (utils.parseBoolean(value) !== true) {
                throw `True spelling not parsed as true: [${value}]`;
            }
        });
    }
    function testFalseSpellings() {
        console.log('  ## testFalseSpellings');
        const spellings = ['false', 'FALSE', 'False', 'FaLsE',
            'no', 'NO', 'No', 'nO', '0'];
        spellings.forEach((value) => {
            if (utils.parseBoolean(value) !== false) {
                throw `False spelling not parsed as false: [${value}]`;
            }
        });
    }
    function testUnrecognizedValuesAreFalse() {
        console.log('  ## testUnrecognizedValuesAreFalse');
        // Unrecognized spellings mean false at parse time: startup
        // validation, not parsing, rejects them. undefined covers unset env
        // vars read at module scope; the near-misses cover whitespace and
        // the on/off family that is deliberately not in the grammar.
        const values = ['on', 'off', 'enabled', 'disabled', '01',
            'yes ', ' true', 'true\n', 'truthy', '', undefined, null];
        values.forEach((value) => {
            if (utils.parseBoolean(value) !== false) {
                throw `Unrecognized value not parsed as false: [${value}]`;
            }
        });
    }

    testCanonicalTable();
    testTrueSpellings();
    testFalseSpellings();
    testUnrecognizedValuesAreFalse();
}

function testParseArray() {
    printHeader('testParseArray');

    function testParseNull() {
        console.log('  ## testParseNull');
        const actual = utils.parseArray(null);
        if (!Array.isArray(actual) || actual.length > 0) {
            throw 'Null not parsed into an empty array';
        }
    }
    function testParseEmptyString() {
        console.log('  ## testParseEmptyString');
        const actual = utils.parseArray('');
        if (!Array.isArray(actual) || actual.length > 0) {
            throw 'Empty string not parsed into an empty array';
        }
    }
    function testParseSingleValue() {
        console.log('  ## testParseSingleValue');
        const value = 'Single Value';
        const actual = utils.parseArray(value);
        if (!Array.isArray(actual) || actual.length !== 1) {
            throw 'Single value not parsed into an array with a single element';
        }
        if (actual[0] !== value) {
            throw `Unexpected array element: ${actual[0]}`
        }
    }
    function testParseMultipleValues() {
        console.log('  ## testParseMultipleValues');
        const values = ['string 1', 'something else', 'Yet another value'];
        const textValues = values.join(';');
        const actual = utils.parseArray(textValues);
        if (!Array.isArray(actual) || actual.length !== values.length) {
            throw 'Multiple values not parsed into an array with the expected length';
        }
        for (let i = 0; i < values.length; i++) {
            if (values[i] !== actual[i]) {
                throw `Unexpected array element [${i}]: ${actual[i]}`
            }
        }
    }

    function testParseMultipleValuesTrailingDelimiter() {
        console.log('  ## testParseMultipleValuesTrailingDelimiter');
        const values = ['string 1', 'something else', 'Yet another value'];
        const textValues = values.join(';');
        const actual = utils.parseArray(textValues + ';');
        if (!Array.isArray(actual) || actual.length !== values.length) {
            throw 'Multiple values not parsed into an array with the expected length';
        }
        for (let i = 0; i < values.length; i++) {
            if (values[i] !== actual[i]) {
                throw `Unexpected array element [${i}]: ${actual[i]}`
            }
        }
    }

    testParseNull();
    testParseEmptyString();
    testParseSingleValue();
    testParseMultipleValues();
    testParseMultipleValuesTrailingDelimiter();
}

function testAmzDatetime() {
    printHeader('testAmzDatetime');
    var timestamp = new Date('2020-08-03T02:01:09.004Z');
    var eightDigitDate = utils.getEightDigitDate(timestamp);
    var amzDatetime = utils.getAmzDatetime(timestamp, eightDigitDate);
    var expected = '20200803T020109Z';

    if (amzDatetime !== expected) {
        throw 'Amazon date time was not created correctly.\n' +
        'Actual:   [' + amzDatetime + ']\n' +
        'Expected: [' + expected + ']';
    }
}

function testEightDigitDate() {
    printHeader('testEightDigitDate');
    var timestamp = new Date('2020-08-03T02:01:09.004Z');
    var eightDigitDate = utils.getEightDigitDate(timestamp);
    var expected = '20200803';

    if (eightDigitDate !== expected) {
        throw 'Eight digit date was not created correctly.\n' +
        'Actual:   ' + eightDigitDate + '\n' +
        'Expected: ' + expected;
    }
}

function testPad() {
    printHeader('testPad');
    var padSingleDigit = utils.padWithLeadingZeros(3, 2);
    var expected = '03';

    if (padSingleDigit !== expected) {
        throw 'Single digit 3 was not padded with leading zero.\n' +
        'Actual:   ' + padSingleDigit + '\n' +
        'Expected: ' + expected;
    }
}

function testAreAllEnvVarsSet() {
    function testAreAllEnvVarsSetStringFound() {
        console.log('  ## testAreAllEnvVarsSetStringFound');
        const key = 'TEST_ENV_VAR_KEY';
        process.env[key] = 'some value';
        const actual = utils.areAllEnvVarsSet(key);
        if (!actual) {
            throw 'Environment variable that was set not indicated as present';
        }
    }

    function testAreAllEnvVarsSetStringNotFound() {
        console.log('  ## testAreAllEnvVarsSetStringNotFound');
        const actual = utils.areAllEnvVarsSet('UNKNOWN_ENV_VAR_KEY');
        if (actual) {
            throw 'Unknown environment variable indicated as being present';
        }
    }

    function testAreAllEnvVarsSetStringArrayFound() {
        console.log('  ## testAreAllEnvVarsSetStringArrayFound');
        const keys = ['TEST_ENV_VAR_KEY_1', 'TEST_ENV_VAR_KEY_2', 'TEST_ENV_VAR_KEY_3'];
        for (let i = 0; i < keys.length; i++) {
            process.env[keys[i]] = 'something';
        }
        const actual = utils.areAllEnvVarsSet(keys);
        if (!actual) {
            throw 'Environment variables that were set not indicated as present';
        }
    }

    function testAreAllEnvVarsSetStringArrayNotFound() {
        console.log('  ## testAreAllEnvVarsSetStringArrayNotFound');
        const keys = ['UNKNOWN_ENV_VAR_KEY_1', 'UNKNOWN_ENV_VAR_KEY_2', 'UNKNOWN_ENV_VAR_KEY_3'];
        const actual = utils.areAllEnvVarsSet(keys);
        if (actual) {
            throw 'Unknown environment variables that were not set indicated as present';
        }
    }

    function testAreAllEnvVarsSetStringArrayWithSomeSet() {
        console.log('  ## testAreAllEnvVarsSetStringArrayWithSomeSet');
        const keys = ['TEST_ENV_VAR_KEY_1', 'UNKNOWN_ENV_VAR_KEY_2', 'UNKNOWN_ENV_VAR_KEY_3'];
        process.env[keys[0]] = 'something';

        const actual = utils.areAllEnvVarsSet(keys);
        if (actual) {
            throw 'Unknown environment variables that were not set indicated as present';
        }
    }

    printHeader('testAreAllEnvVarsSet');
    testAreAllEnvVarsSetStringFound();
    testAreAllEnvVarsSetStringNotFound();
    testAreAllEnvVarsSetStringArrayFound();
    testAreAllEnvVarsSetStringArrayNotFound();
    testAreAllEnvVarsSetStringArrayWithSomeSet();
}


function testReadEnvVarOrFile() {
    printHeader('testReadEnvVarOrFile');

    const settingName = 'TEST_SECRET_SETTING';
    const fileSettingName = settingName + '_FILE';
    const secretPath = '/tmp/test_secret_setting';

    /* Assigning undefined would re-create the key and break the presence
       checks that readEnvVarOrFile makes, so delete it instead. */
    function restoreEnv(name, saved) {
        if (saved === undefined) {
            delete process.env[name];
        } else {
            process.env[name] = saved;
        }
    }

    /* readEnvVarOrFile memoizes what it reads, so every case starts from a
       clean cache as well as a clean environment. */
    function withCleanEnv(body) {
        const savedDirect = process.env[settingName];
        const savedFile = process.env[fileSettingName];
        delete process.env[settingName];
        delete process.env[fileSettingName];
        utils.resetEnvVarFileCache();
        try {
            body();
        } finally {
            restoreEnv(settingName, savedDirect);
            restoreEnv(fileSettingName, savedFile);
            utils.resetEnvVarFileCache();
            /* The path is fixed rather than unique, so leaving the file behind
               would let one case's contents leak into the next run. */
            if (fs.statSync(secretPath, {throwIfNoEntry: false})) {
                fs.unlinkSync(secretPath);
            }
        }
    }

    function testNeitherFormSet() {
        console.log('  ## testNeitherFormSet');
        withCleanEnv(function () {
            const actual = utils.readEnvVarOrFile(settingName);
            if (actual !== undefined) {
                throw `Unset setting did not read as undefined\nActual:   [${actual}]`;
            }
        });
    }

    function testDirectValue() {
        console.log('  ## testDirectValue');
        withCleanEnv(function () {
            process.env[settingName] = 'from_env';
            const actual = utils.readEnvVarOrFile(settingName);
            if (actual !== 'from_env') {
                throw `Value not read from the environment variable\nActual:   [${actual}]\nExpected: [from_env]`;
            }
        });
    }

    function testDirectValueWinsOverFile() {
        console.log('  ## testDirectValueWinsOverFile');
        withCleanEnv(function () {
            fs.writeFileSync(secretPath, 'from_file');
            process.env[settingName] = 'from_env';
            process.env[fileSettingName] = secretPath;
            const actual = utils.readEnvVarOrFile(settingName);
            if (actual !== 'from_env') {
                throw `File value did not lose to the environment variable\nActual:   [${actual}]\nExpected: [from_env]`;
            }
        });
    }

    function testFileValue() {
        console.log('  ## testFileValue');
        withCleanEnv(function () {
            fs.writeFileSync(secretPath, 'from_file');
            process.env[fileSettingName] = secretPath;
            const actual = utils.readEnvVarOrFile(settingName);
            if (actual !== 'from_file') {
                throw `Value not read from the file\nActual:   [${actual}]\nExpected: [from_file]`;
            }
        });
    }

    function testFileValueIsTrimmed() {
        console.log('  ## testFileValueIsTrimmed');
        withCleanEnv(function () {
            fs.writeFileSync(secretPath, '  from_file\n');
            process.env[fileSettingName] = secretPath;
            const actual = utils.readEnvVarOrFile(settingName);
            if (actual !== 'from_file') {
                throw `Surrounding whitespace not trimmed from the file value\nActual:   [${actual}]\nExpected: [from_file]`;
            }
        });
    }

    function testFileValueIsMemoized() {
        console.log('  ## testFileValueIsMemoized');
        withCleanEnv(function () {
            fs.writeFileSync(secretPath, 'first_value');
            process.env[fileSettingName] = secretPath;
            utils.readEnvVarOrFile(settingName);
            fs.writeFileSync(secretPath, 'second_value');
            const actual = utils.readEnvVarOrFile(settingName);
            if (actual !== 'first_value') {
                throw `File was re-read instead of memoized\nActual:   [${actual}]\nExpected: [first_value]`;
            }
        });
    }

    function testMissingFileThrows() {
        console.log('  ## testMissingFileThrows');
        withCleanEnv(function () {
            process.env[fileSettingName] = '/tmp/no_such_secret_file';
            let thrown = null;
            try {
                utils.readEnvVarOrFile(settingName);
            } catch (e) {
                thrown = e;
            }
            if (thrown === null) {
                throw 'An unreadable secret file did not throw';
            }
            if (thrown.indexOf(fileSettingName) < 0) {
                throw `Error did not name the setting that failed\nActual:   [${thrown}]`;
            }
        });
    }

    function testEmptyFileThrows() {
        console.log('  ## testEmptyFileThrows');
        withCleanEnv(function () {
            fs.writeFileSync(secretPath, '\n   \n');
            process.env[fileSettingName] = secretPath;
            let thrown = null;
            try {
                utils.readEnvVarOrFile(settingName);
            } catch (e) {
                thrown = e;
            }
            if (thrown === null) {
                throw 'A whitespace-only secret file did not throw';
            }
            if (thrown.indexOf('empty file') < 0) {
                throw `Error did not report an empty file\nActual:   [${thrown}]`;
            }
        });
    }

    testNeitherFormSet();
    testDirectValue();
    testDirectValueWinsOverFile();
    testFileValue();
    testFileValueIsTrimmed();
    testFileValueIsMemoized();
    testMissingFileThrows();
    testEmptyFileThrows();
}


async function test() {
    testAmzDatetime();
    testEightDigitDate();
    testPad();
    testParseBoolean();
    testParseArray();
    testAreAllEnvVarsSet();
    testReadEnvVarOrFile();
}
    
function printHeader(testName) {
    console.log(`\n## ${testName}`);
}

test();
console.log('Finished unit tests for utils.js');

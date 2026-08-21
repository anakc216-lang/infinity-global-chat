// Test script for Privacy & Safety implementation
const fs = require('fs');
const html = fs.readFileSync('./index.html', 'utf8');

console.log('=== PRIVACY & SAFETY IMPLEMENTATION VALIDATION ===\n');

const tests = {
  'Safety screen HTML': html.includes('id="safetyScreen"'),
  'Safety header text': html.includes('Stay Safe'),
  'Investment Scams warning': html.includes('Investment Scams'),
  'Love & Romance Scams': html.includes('Love & Romance Scams'),
  'Phishing Scams': html.includes('Phishing Scams'),
  'Fake Offers & Giveaways': html.includes('Fake Offers & Giveaways'),
  'Impersonation Scams': html.includes('Impersonation Scams'),
  'Safety nav button': html.includes('data-screen="safety"'),
  'Link safety modal': html.includes('id="linkSafetyModal"'),
  'Yes I Understand button': html.includes('id="linkSafetyUnderstandBtn"'),
  'OK Continue button': html.includes('id="linkSafetyContinueBtn"'),
  'Go Back button': html.includes('id="linkSafetyBackBtn"'),
  'External link data attribute': html.includes('data-external-link'),
  'External link CSS class': html.includes('class="external-link"'),
  'Link safety modal content': html.includes('Never enter your password'),
  'Linkify function updated': html.includes('pendingLinkUrl'),
  'OpenLinkSafetyModal function': html.includes('function openLinkSafetyModal'),
  'CloseLinkSafetyModal function': html.includes('function closeLinkSafetyModal'),
  'External link click handler': html.includes('.external-link'),
  'Safety screen toggle': html.includes('toggle.*safety'),
};

let passCount = 0;
let failedTests = [];

console.log('Test Results:');
console.log('-'.repeat(50));

Object.entries(tests).forEach(([name, result]) => {
  const status = result ? '✓' : '✗';
  console.log(`${status} ${name}`);
  if (result) passCount++;
  else failedTests.push(name);
});

console.log('-'.repeat(50));
console.log(`\nResults: ${passCount}/${Object.keys(tests).length} tests passed`);

if (failedTests.length > 0) {
  console.log('\nFailed tests:');
  failedTests.forEach(t => console.log(`  - ${t}`));
}

if (passCount === Object.keys(tests).length) {
  console.log('\n✓ ALL TESTS PASSED - Implementation is complete!');
  process.exit(0);
} else {
  console.log('\n✗ Some tests failed - please review implementation');
  process.exit(1);
}

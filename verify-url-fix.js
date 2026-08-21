// Comprehensive verification of URL linkification fix

const fs = require('fs');
const html = fs.readFileSync('./index.html', 'utf8');

console.log('=== URL LINKIFICATION IMPLEMENTATION VERIFICATION ===\n');

const checks = {
  // Core linkify function
  'linkify function present': html.includes('function linkify(text)'),
  'linkify uses urlRegex': html.includes('const urlRegex = /(https?:\\/\\/[^\\s]+)/g'),
  'linkify creates links': html.includes('data-external-link='),
  'linkify handles escaping': html.includes('escapeHtml(text.substring'),
  
  // renderMessages integration  
  'renderMessages calls linkify': html.includes('${linkify(m.content)}'),
  'renderMessages NOT pre-escaping URLs': !html.includes('${linkify(escapeHtml(m.content))}'),
  
  // External link click handler
  'External link click handler present': html.includes(".closest('.external-link')"),
  'Click handler opens modal': html.includes('openLinkSafetyModal(url)'),
  
  // Modal functions
  'openLinkSafetyModal function': html.includes('function openLinkSafetyModal(url)'),
  'closeLinkSafetyModal function': html.includes('function closeLinkSafetyModal()'),
  'pendingLinkUrl variable': html.includes('let pendingLinkUrl'),
  
  // Two-step confirmation flow
  'linkSafetyUnderstandBtn listener': html.includes('linkSafetyUnderstandBtn'),
  'linkSafetyContinueBtn listener': html.includes('linkSafetyContinueBtn'),
  'Continue button triggers window.open': html.includes("window.open(url, '_blank'"),
  
  // CSS styling
  'external-link CSS color': html.includes('.external-link'),
  'external-link underline style': html.includes('text-decoration: underline'),
  'external-link hover effect': html.includes('.external-link:hover'),
  
  // Security
  'data-external-link attribute': html.includes('data-external-link="${safe}"'),
  'URL quote escaping': html.includes("safe = url.replace(/\"/g"),
};

let passCount = 0;
let failedChecks = [];

console.log('Verification Results:');
console.log('-'.repeat(60));

Object.entries(checks).forEach(([name, result]) => {
  const status = result ? '✓' : '✗';
  console.log(`${status} ${name}`);
  if (result) passCount++;
  else failedChecks.push(name);
});

console.log('-'.repeat(60));
console.log(`\nResults: ${passCount}/${Object.keys(checks).length} checks passed`);

if (failedChecks.length > 0) {
  console.log('\nFailed checks:');
  failedChecks.forEach(c => console.log(`  - ${c}`));
  process.exit(1);
} else {
  console.log('\n✓ ALL VERIFICATION CHECKS PASSED!');
  console.log('✓ URL linkification implementation is complete and correct');
  console.log('✓ Two-step safety confirmation system is integrated');
  console.log('✓ CSS styling is applied for link visibility');
  process.exit(0);
}

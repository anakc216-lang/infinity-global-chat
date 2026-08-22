// Test the URL linkification fix

// Replicate escapeHtml and linkify functions from index.html
function escapeHtml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function linkify(text) {
  const urlRegex = /(https?:\/\/[^\s]+)/g;
  let lastIndex = 0;
  let result = '';
  
  let match;
  while ((match = urlRegex.exec(text)) !== null) {
    // Escape the part before the URL
    result += escapeHtml(text.substring(lastIndex, match.index));
    
    // Create the link with the original (un-escaped) URL
    const url = match[1];
    const safe = url.replace(/"/g, '&quot;');
    result += `<a href="#" data-external-link="${safe}" class="external-link">${escapeHtml(url)}</a>`;
    
    lastIndex = urlRegex.lastIndex;
  }
  
  // Escape the remaining part
  result += escapeHtml(text.substring(lastIndex));
  
  return result;
}

console.log('=== URL LINKIFICATION TEST ===\n');

const testCases = [
  'Check this https://example.com out!',
  'Visit https://www.example.com?a=1&b=2 for more info',
  'http://example.com is cool',
  'Multiple links: https://example.com and https://test.com',
  'No links here just plain text',
  'Link at start https://example.com',
  'Link at end is https://example.com',
  'Multiple words https://example.com/path?query=value&other=123',
];

let allPassed = true;

testCases.forEach((testText, i) => {
  console.log(`Test ${i + 1}: "${testText}"`);
  const result = linkify(testText);
  
  // Check if result contains proper link structure
  const hasExternalLink = result.includes('class="external-link"');
  const hasDataAttr = result.includes('data-external-link');
  const hasAnchor = result.includes('<a href="#"');
  
  // Verify no double-escaped ampersands (&amp;amp;)
  const hasDoubleEscape = result.includes('&amp;amp;');
  
  // Count URLs in input vs links in output
  const urlCount = (testText.match(/(https?:\/\/[^\s]+)/g) || []).length;
  const linkCount = (result.match(/class="external-link"/g) || []).length;
  
  // If there are no URLs, the message should still be properly escaped
  const noUrlsCase = urlCount === 0 && !hasDoubleEscape;
  const hasUrlsCase = urlCount > 0 && hasExternalLink && hasDataAttr && hasAnchor && !hasDoubleEscape && (urlCount === linkCount);
  
  const passed = noUrlsCase || hasUrlsCase;
  
  console.log(`  URLs found: ${urlCount}`);
  console.log(`  Links created: ${linkCount}`);
  console.log(`  Has proper link HTML: ${hasExternalLink ? '✓' : '✗'}`);
  console.log(`  Has data-external-link: ${hasDataAttr ? '✓' : '✗'}`);
  console.log(`  No double-escape: ${!hasDoubleEscape ? '✓' : '✗'}`);
  console.log(`  Result: ${passed ? '✓ PASS' : '✗ FAIL'}`);
  
  if (passed) {
    console.log(`  HTML: ${result.substring(0, 100)}...`);
  } else {
    console.log(`  HTML: ${result}`);
    allPassed = false;
  }
  console.log('');
});

console.log('='.repeat(50));
if (allPassed) {
  console.log('✓ ALL TESTS PASSED - URL linkification is working correctly!');
  process.exit(0);
} else {
  console.log('✗ Some tests failed - please review');
  process.exit(1);
}

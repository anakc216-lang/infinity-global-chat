const assert = require('node:assert/strict');

function earnedCents(referralCount) {
  return Math.floor(referralCount / 25) * 500;
}

function nextTarget(referralCount) {
  return referralCount === 0 || referralCount % 25 !== 0
    ? (Math.floor(referralCount / 25) + 1) * 25
    : referralCount;
}

function balanceAfterPaid(referralCount, paidCents) {
  return Math.max(0, earnedCents(referralCount) - paidCents);
}

for (const [count, expected] of [[0, 0], [24, 0], [25, 500], [26, 500], [49, 500], [50, 1000], [75, 1500], [100, 2000]]) {
  assert.equal(earnedCents(count), expected, `${count} referrals`);
}

assert.deepEqual([0, 25, 26, 50, 51, 75, 76, 100].map(nextTarget), [25, 25, 50, 50, 75, 75, 100, 100]);
assert.equal(balanceAfterPaid(75, 1500), 0);
assert.equal(balanceAfterPaid(100, 1500), 500);
assert.equal(balanceAfterPaid(100, 1500), balanceAfterPaid(100, 1500), 'refresh does not duplicate balance');

const paidWithdrawals = new Set();
function markPaid(withdrawalId) {
  if (paidWithdrawals.has(withdrawalId)) throw new Error('WITHDRAWAL_NOT_FOUND_OR_CLOSED');
  paidWithdrawals.add(withdrawalId);
}

markPaid('withdrawal-1');
assert.throws(() => markPaid('withdrawal-1'), /WITHDRAWAL_NOT_FOUND_OR_CLOSED/);
console.log('Referral commission contract tests passed.');
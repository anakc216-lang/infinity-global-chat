const fs = require('fs');
const path = require('path');
const QRCode = require('qrcode');

const baseUrl = 'https://infinity-global-chat.onrender.com';
const outputDirectory = path.join(__dirname, 'qr-codes');
const referrals = Array.from({ length: 30 }, (_, index) => {
  const number = String(index + 1).padStart(3, '0');
  const referralId = `KEDAI${number}`;
  const fileName = `qr-kedai-${number}.png`;
  return {
    kedaiNumber: index + 1,
    referralId,
    url: `${baseUrl}/?ref=${referralId}`,
    fileName
  };
});

fs.mkdirSync(outputDirectory, { recursive: true });

(async () => {
  for (const referral of referrals) {
    await QRCode.toFile(path.join(outputDirectory, referral.fileName), referral.url, {
      type: 'png',
      width: 800,
      margin: 4,
      errorCorrectionLevel: 'H',
      color: { dark: '#111111', light: '#ffffff' }
    });
  }

  fs.writeFileSync(
    path.join(outputDirectory, 'qr-list.json'),
    `${JSON.stringify(referrals, null, 2)}\n`,
    'utf8'
  );
  console.log(`Generated ${referrals.length} referral QR codes in ${outputDirectory}`);
})();

// Tests de la formule des frais de paiement (node --test). Mêmes cas que mobile/test/format_test.dart.
const test = require('node:test');
const assert = require('node:assert/strict');
const fees = require('../src/payments/fees');

test('cas de référence (identiques à l\'app)', () => {
  // 20 000 F + 1 000 F de livraison = 21 000 F à recevoir.
  assert.equal(fees.grossUp(21000, 2), 21429);
  assert.equal(fees.customerFee(21000, 2), 429);
  assert.equal(fees.providerFeeOn(21429, 2), 429);
  assert.equal(fees.grossUp(21000, 3.5), 21762);
  assert.equal(fees.customerFee(21000, 3.5), 762);
  assert.equal(fees.providerFeeOn(21762, 3.5), 762);
  assert.equal(fees.customerFee(4000, 2), 82);
  assert.equal(fees.customerFee(4000, 2.5), 103);
  assert.equal(fees.customerFee(4000, 0), 0);
  assert.equal(fees.customerFee(21000, 1), 213);
  assert.equal(fees.customerFee(21000, 3), 650);
});

test('le restaurant reçoit sous-total + livraison (écart ≤ 1 F), quel que soit l\'arrondi de l\'agrégateur', () => {
  const rates = [0, 1, 2, 2.5, 3, 3.5];
  let checked = 0;
  for (const p of rates) {
    for (let base = 2000; base <= 200000; base += 1) {
      const gross = fees.grossUp(base, p);
      const exact = (gross * p) / 100;
      // Arrondi supposé (supérieur), au plus proche, à l'inférieur : net toujours ≥ base et ≤ base + 1.
      for (const fee of [fees.providerFeeOn(gross, p), Math.round(exact), Math.floor(exact)]) {
        const net = gross - fee;
        if (net < base || net > base + 1) assert.fail(`p=${p} base=${base} brut=${gross} frais=${fee} net=${net}`);
      }
      // Avec l'arrondi supposé, net = base exactement.
      if (gross - fees.providerFeeOn(gross, p) !== base) assert.fail(`net ≠ base pour p=${p} base=${base}`);
      // Brut minimal : un franc de moins ne suffirait pas.
      if (p > 0 && gross - 1 - fees.providerFeeOn(gross - 1, p) >= base) assert.fail(`brut non minimal p=${p} base=${base}`);
      checked++;
    }
  }
  assert.equal(checked, rates.length * 198001);
});

test('taux : variables d\'environnement par opérateur, repli', () => {
  const saved = { ...process.env };
  try {
    delete process.env.PROVIDER_FEE_PERCENT;
    process.env.PROVIDER_FEE_PERCENT_FLOOZ = '3,5';
    assert.equal(fees.envPercent('PROVIDER_FEE_PERCENT_FLOOZ'), 3.5);
    process.env.PROVIDER_FEE_PERCENT_MIXX = 'abc';
    assert.equal(fees.envPercent('PROVIDER_FEE_PERCENT_MIXX'), null);
    process.env.PROVIDER_FEE_PERCENT_MIXX = '';
    assert.equal(fees.envPercent('PROVIDER_FEE_PERCENT_MIXX'), null);
    process.env.PROVIDER_FEE_PERCENT_MIXX = '25';
    assert.equal(fees.envPercent('PROVIDER_FEE_PERCENT_MIXX'), null);
    assert.equal(fees.basisPoints(2.5), 250);
    assert.equal(fees.basisPoints(-1), 0);
  } finally {
    process.env = saved;
  }
});

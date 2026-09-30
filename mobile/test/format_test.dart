import 'package:flutter_test/flutter_test.dart';
import 'package:ivrivrii_chicken/models.dart';
import 'package:ivrivrii_chicken/providers/cart_provider.dart';
import 'package:ivrivrii_chicken/utils/format.dart';

void main() {
  test('formatPrice groupe les milliers', () {
    expect(formatPrice(700), '700 FCFA');
    expect(formatPrice(7000), '7 000 FCFA');
    expect(formatPrice(1250000), '1 250 000 FCFA');
  });

  test('frais de paiement : identiques au serveur, arrondis au supérieur', () {
    expect(paymentFeeFor(4000, 'flooz', 2), 80);
    expect(paymentFeeFor(4050, 'mixx', 2), 81); // 81 pile
    expect(paymentFeeFor(4010, 'flooz', 2), 81); // 80,2 -> 81
    expect(paymentFeeFor(4000, 'flooz', 2.5), 100);
    expect(paymentFeeFor(4000, 'cash', 2), 0);
    expect(formatPercent(2.0), '2');
    expect(formatPercent(2.5), '2,5');
  });

  test('moyens de paiement alignés sur le serveur (flooz, mixx)', () {
    expect(paymentMethods.keys, ['cash', 'flooz', 'mixx']);
    expect(isMobileMoney('mixx'), isTrue);
    expect(isMobileMoney('cash'), isFalse);
    expect(paymentLabel('tmoney'), 'T-Money'); // anciennes commandes
  });

  test('nextStatus suit le mode de retrait', () {
    expect(nextStatus('ready', true), 'delivering');
    expect(nextStatus('ready', false), 'delivered');
    expect(nextStatus('delivered', true), isNull);
  });

  test('le panier calcule quantités et sous-total', () {
    final cart = CartProvider();
    final poulet = Product(id: 1, name: 'Poulet', price: 3800);
    final alloco = Product(id: 2, name: 'Alloco', price: 1000);
    cart.add(poulet);
    cart.add(poulet, 2);
    cart.add(alloco);
    expect(cart.count, 4);
    expect(cart.subtotal, 3 * 3800 + 1000);
    cart.setQuantity(1, 0);
    expect(cart.count, 1);
    expect(cart.toOrderItems(), [
      {'product_id': 2, 'quantity': 1},
    ]);
  });
}

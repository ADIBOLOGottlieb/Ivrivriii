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

  test('quantité plafonnée à $maxQuantityPerItem par article', () {
    expect(maxQuantityPerItem, 999);
    final cart = CartProvider();
    final poulet = Product(id: 1, name: 'Poulet', price: 3800);
    cart.add(poulet, 120);
    expect(cart.quantityOf(1), 120); // plus de limite à 50
    cart.add(poulet, 900);
    expect(cart.quantityOf(1), maxQuantityPerItem);
    cart.setQuantity(1, 5000);
    expect(cart.quantityOf(1), 999);
    cart.setQuantity(1, 998);
    cart.add(poulet);
    cart.add(poulet);
    expect(cart.quantityOf(1), 999);
    cart.add(Product(id: 2, name: 'Alloco', price: 1000), 2000);
    expect(cart.quantityOf(2), 999);
    cart.add(poulet, 0); // ignoré
    expect(cart.quantityOf(1), 999);
  });

  test('saisie de quantité au clavier', () {
    expect(parseQuantity('12'), 12);
    expect(parseQuantity(' 999 '), 999);
    expect(parseQuantity('1000'), isNull);
    expect(parseQuantity('0'), isNull);
    expect(parseQuantity('0', min: 0), 0); // 0 = retirer l'article
    expect(parseQuantity(''), isNull);
    expect(parseQuantity('abc'), isNull);
  });

  test('statut de paiement et compte à rebours', () {
    expect(paymentStatusLabel('refunded'), 'Remboursé');
    expect(paymentStatusLabel('failed'), 'Paiement non abouti');
    expect(paymentStatusLabel('expired'), 'Paiement non abouti');
    expect(paymentStatusLabel('paid'), 'Payée');
    expect(formatCountdown(const Duration(minutes: 2)), '2:00');
    expect(formatCountdown(const Duration(seconds: 65)), '1:05');
    expect(formatCountdown(const Duration(seconds: -3)), '0:00');
  });

  test('estimation du panier = formule serveur (sous-total + livraison + frais)', () {
    const subtotal = 20000, delivery = 1000;
    final fee = paymentFeeFor(subtotal + delivery, 'flooz', 2);
    expect(fee, 420);
    expect(subtotal + delivery + fee, 21420);
  });
}

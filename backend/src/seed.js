const bcrypt = require('bcryptjs');
const { db, transaction } = require('./db');

const CATEGORIES = [
  { name: 'Poulets', icon: 'chicken' },
  { name: 'Burgers', icon: 'burger' },
  { name: 'Grillades', icon: 'grill' },
  { name: 'Accompagnements', icon: 'fries' },
  { name: 'Boissons', icon: 'drink' },
  { name: 'Desserts', icon: 'dessert' },
];

// [category index, name, description, price FCFA, popular, image]
const PRODUCTS = [
  [0, 'Poulet braisé entier', 'Poulet fermier braisé au feu de bois, sauce pimentée maison', 7000, 1, 'https://images.unsplash.com/photo-1598103442097-8b74394b95c6?w=800'],
  [0, 'Demi-poulet braisé', 'Demi-poulet braisé, oignons et piment frais', 3800, 1, 'https://images.unsplash.com/photo-1532550907401-a500c9a57435?w=800'],
  [0, 'Poulet frit croustillant (6 pcs)', 'Morceaux de poulet panés et croustillants, recette Ivrivrii', 4500, 1, 'https://images.unsplash.com/photo-1626645738196-c2a7c87a8f58?w=800'],
  [0, 'Ailes de poulet épicées (8 pcs)', 'Ailes marinées et grillées, sauce barbecue', 3500, 0, 'https://images.unsplash.com/photo-1608039755401-742074f0548d?w=800'],
  [1, 'Chicken Burger', 'Filet de poulet croustillant, salade, tomate, sauce maison', 3000, 1, 'https://images.unsplash.com/photo-1606755962773-d324e0a13086?w=800'],
  [1, 'Double Cheese Chicken', 'Double filet de poulet, cheddar fondu, oignons caramélisés', 4200, 0, 'https://images.unsplash.com/photo-1553979459-d2229ba7433b?w=800'],
  [2, 'Brochettes de bœuf', '4 brochettes de bœuf marinées, sauce arachide', 3500, 0, 'https://images.unsplash.com/photo-1603360946369-dc9bb6258143?w=800'],
  [2, 'Steak grillé', 'Steak de bœuf grillé, légumes sautés', 5500, 0, 'https://images.unsplash.com/photo-1546964124-0cce460f38ef?w=800'],
  [3, 'Attiéké', 'Portion d\'attiéké frais', 700, 0, 'https://images.unsplash.com/photo-1512058564366-18510be2db19?w=800'],
  [3, 'Alloco', 'Bananes plantain frites', 1000, 1, 'https://images.unsplash.com/photo-1528751014936-863e6e7a319c?w=800'],
  [3, 'Frites maison', 'Frites croustillantes', 1000, 0, 'https://images.unsplash.com/photo-1573080496219-bb080dd4f877?w=800'],
  [3, 'Salade fraîche', 'Laitue, tomate, concombre, oignon', 1200, 0, 'https://images.unsplash.com/photo-1512621776951-a57141f2eefd?w=800'],
  [4, 'Bissap', 'Jus d\'hibiscus maison (50 cl)', 700, 0, 'https://images.unsplash.com/photo-1556679343-c7306c1976bc?w=800'],
  [4, 'Gnamakoudji', 'Jus de gingembre maison (50 cl)', 700, 0, 'https://images.unsplash.com/photo-1600271886742-f049cd451bba?w=800'],
  [4, 'Coca-Cola', 'Canette 33 cl', 800, 0, 'https://images.unsplash.com/photo-1554866585-cd94860890b7?w=800'],
  [5, 'Salade de fruits', 'Fruits frais de saison', 1500, 0, 'https://images.unsplash.com/photo-1564093497595-593b96d80180?w=800'],
];

function seedIfEmpty() {
  const hasAdmin = db.prepare(`SELECT id FROM users WHERE role = 'admin' LIMIT 1`).get();
  if (!hasAdmin) {
    const phone = process.env.ADMIN_PHONE || '0700000000';
    const password = process.env.ADMIN_PASSWORD || 'admin123';
    db.prepare(`INSERT INTO users (name, phone, password_hash, role) VALUES (?, ?, ?, 'admin')`).run(
      'Administrateur', phone, bcrypt.hashSync(password, 10),
    );
    console.log(`👤 Compte admin créé : ${phone} / ${password} (changez le mot de passe !)`);
  }

  const hasCategories = db.prepare('SELECT id FROM categories LIMIT 1').get();
  if (!hasCategories) {
    transaction(() => {
      const insertCat = db.prepare('INSERT INTO categories (name, icon, position) VALUES (?, ?, ?)');
      const ids = CATEGORIES.map((c, i) => insertCat.run(c.name, c.icon, i).lastInsertRowid);
      const insertProduct = db.prepare(
        'INSERT INTO products (category_id, name, description, price, popular, image_url) VALUES (?, ?, ?, ?, ?, ?)',
      );
      for (const [cat, name, desc, price, popular, img] of PRODUCTS) {
        insertProduct.run(ids[cat], name, desc, price, popular, img);
      }
    });
    console.log('🍗 Menu de démonstration ajouté');
  }
}

if (require.main === module) seedIfEmpty();

module.exports = { seedIfEmpty };

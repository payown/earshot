import Foundation

/// One Apple Podcasts chart category. The IDs are Apple's public podcast genre
/// identifiers and are deliberately kept as strings because they are URL path
/// components, not values Earshot calculates with.
struct ApplePodcastCategory: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let subcategories: [ApplePodcastCategory]

    init(id: String, name: String, subcategories: [ApplePodcastCategory] = []) {
        self.id = id
        self.name = name
        self.subcategories = subcategories
    }
}

/// Apple's current podcast category hierarchy. Keeping this small taxonomy in
/// the app makes the category picker instant and available offline; selecting a
/// category still fetches the live, storefront-specific chart from Apple.
enum ApplePodcastCategories {
    static let all: [ApplePodcastCategory] = [
        .init(id: "1301", name: "Arts", subcategories: [
            .init(id: "1482", name: "Books"),
            .init(id: "1402", name: "Design"),
            .init(id: "1459", name: "Fashion & Beauty"),
            .init(id: "1306", name: "Food"),
            .init(id: "1405", name: "Performing Arts"),
            .init(id: "1406", name: "Visual Arts"),
        ]),
        .init(id: "1321", name: "Business", subcategories: [
            .init(id: "1410", name: "Careers"),
            .init(id: "1493", name: "Entrepreneurship"),
            .init(id: "1412", name: "Investing"),
            .init(id: "1491", name: "Management"),
            .init(id: "1492", name: "Marketing"),
            .init(id: "1494", name: "Non-Profit"),
        ]),
        .init(id: "1303", name: "Comedy", subcategories: [
            .init(id: "1496", name: "Comedy Interviews"),
            .init(id: "1495", name: "Improv"),
            .init(id: "1497", name: "Stand-Up"),
        ]),
        .init(id: "1304", name: "Education", subcategories: [
            .init(id: "1501", name: "Courses"),
            .init(id: "1499", name: "How To"),
            .init(id: "1498", name: "Language Learning"),
            .init(id: "1500", name: "Self-Improvement"),
        ]),
        .init(id: "1483", name: "Fiction", subcategories: [
            .init(id: "1486", name: "Comedy Fiction"),
            .init(id: "1484", name: "Drama"),
            .init(id: "1485", name: "Science Fiction"),
        ]),
        .init(id: "1511", name: "Government"),
        .init(id: "1512", name: "Health & Fitness", subcategories: [
            .init(id: "1513", name: "Alternative Health"),
            .init(id: "1514", name: "Fitness"),
            .init(id: "1518", name: "Medicine"),
            .init(id: "1517", name: "Mental Health"),
            .init(id: "1515", name: "Nutrition"),
            .init(id: "1516", name: "Sexuality"),
        ]),
        .init(id: "1487", name: "History"),
        .init(id: "1305", name: "Kids & Family", subcategories: [
            .init(id: "1519", name: "Education for Kids"),
            .init(id: "1521", name: "Parenting"),
            .init(id: "1522", name: "Pets & Animals"),
            .init(id: "1520", name: "Stories for Kids"),
        ]),
        .init(id: "1502", name: "Leisure", subcategories: [
            .init(id: "1510", name: "Animation & Manga"),
            .init(id: "1503", name: "Automotive"),
            .init(id: "1504", name: "Aviation"),
            .init(id: "1506", name: "Crafts"),
            .init(id: "1507", name: "Games"),
            .init(id: "1505", name: "Hobbies"),
            .init(id: "1508", name: "Home & Garden"),
            .init(id: "1509", name: "Video Games"),
        ]),
        .init(id: "1310", name: "Music", subcategories: [
            .init(id: "1523", name: "Music Commentary"),
            .init(id: "1524", name: "Music History"),
            .init(id: "1525", name: "Music Interviews"),
        ]),
        .init(id: "1489", name: "News", subcategories: [
            .init(id: "1490", name: "Business News"),
            .init(id: "1526", name: "Daily News"),
            .init(id: "1531", name: "Entertainment News"),
            .init(id: "1530", name: "News Commentary"),
            .init(id: "1527", name: "Politics"),
            .init(id: "1529", name: "Sports News"),
            .init(id: "1528", name: "Tech News"),
        ]),
        .init(id: "1314", name: "Religion & Spirituality", subcategories: [
            .init(id: "1438", name: "Buddhism"),
            .init(id: "1439", name: "Christianity"),
            .init(id: "1463", name: "Hinduism"),
            .init(id: "1440", name: "Islam"),
            .init(id: "1441", name: "Judaism"),
            .init(id: "1532", name: "Religion"),
            .init(id: "1444", name: "Spirituality"),
        ]),
        .init(id: "1533", name: "Science", subcategories: [
            .init(id: "1538", name: "Astronomy"),
            .init(id: "1539", name: "Chemistry"),
            .init(id: "1540", name: "Earth Sciences"),
            .init(id: "1541", name: "Life Sciences"),
            .init(id: "1536", name: "Mathematics"),
            .init(id: "1534", name: "Natural Sciences"),
            .init(id: "1537", name: "Nature"),
            .init(id: "1542", name: "Physics"),
            .init(id: "1535", name: "Social Sciences"),
        ]),
        .init(id: "1324", name: "Society & Culture", subcategories: [
            .init(id: "1543", name: "Documentary"),
            .init(id: "1302", name: "Personal Journals"),
            .init(id: "1443", name: "Philosophy"),
            .init(id: "1320", name: "Places & Travel"),
            .init(id: "1544", name: "Relationships"),
        ]),
        .init(id: "1545", name: "Sports", subcategories: [
            .init(id: "1549", name: "Baseball"),
            .init(id: "1548", name: "Basketball"),
            .init(id: "1554", name: "Cricket"),
            .init(id: "1560", name: "Fantasy Sports"),
            .init(id: "1547", name: "American Football"),
            .init(id: "1553", name: "Golf"),
            .init(id: "1550", name: "Hockey"),
            .init(id: "1552", name: "Rugby"),
            .init(id: "1551", name: "Running"),
            .init(id: "1546", name: "Football (Soccer)"),
            .init(id: "1558", name: "Swimming"),
            .init(id: "1556", name: "Tennis"),
            .init(id: "1557", name: "Volleyball"),
            .init(id: "1559", name: "Wilderness"),
            .init(id: "1555", name: "Wrestling"),
        ]),
        .init(id: "1318", name: "Technology"),
        .init(id: "1488", name: "True Crime"),
        .init(id: "1309", name: "TV & Film", subcategories: [
            .init(id: "1562", name: "After Shows"),
            .init(id: "1564", name: "Film History"),
            .init(id: "1565", name: "Film Interviews"),
            .init(id: "1563", name: "Film Reviews"),
            .init(id: "1561", name: "TV Reviews"),
        ]),
    ]
}

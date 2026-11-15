//
//  TagTaxonomy.swift
//  photos analyze
//

import Foundation

/// The app's tag vocabulary: which raw labels (from Vision or Apple Intelligence) are
/// worth tagging, which names mean the same thing, and which tags imply broader ones
/// ("Surfing" → "Watersport" → "Sport").
///
/// The user's own decisions always win: a label the user deleted or merged (see
/// `TagMerges`) is mapped by their rule before and after this vocabulary is applied.
nonisolated enum TagTaxonomy {

    // MARK: Lookup

    /// Lowercased, underscores and repeated spaces collapsed ("sand_dune" → "sand dune").
    static func key(_ tag: String) -> String {
        tag.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// The library tag for a raw label, or nil if it shouldn't become a tag (noise, or
    /// deleted by the user).
    static func canonical(_ raw: String, merges: [String: String]) -> String? {
        let k = key(raw)
        guard !k.isEmpty else { return nil }
        // The user's rule for the raw name comes first ("flower" deleted stays deleted).
        if let target = merges[k] ?? merges[raw.lowercased()] {
            return target.isEmpty ? nil : target
        }
        guard !ignored.contains(k) else { return nil }
        let name = synonyms[k] ?? ShotClassifier.prettify(k)
        if let target = merges[name.lowercased()] {
            return target.isEmpty ? nil : target
        }
        return name
    }

    /// Maps raw labels to library tags, dropping noise, tags the user deleted, tags in
    /// `suppressed` (lowercased) and duplicates ("Pole" and "Lamppost" → one "Pole";
    /// "Jet plane" and "jet planes" → one tag).
    static func clean(_ raw: [String], merges: [String: String], suppressed: Set<String> = []) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for label in raw {
            guard let tag = canonical(label, merges: merges),
                  !suppressed.contains(tag.lowercased()),
                  seen.insert(SimilarTags.normalized(tag)).inserted
            else { continue }
            result.append(tag)
        }
        return result
    }

    /// The Vision confidence a label needs to become a tag. Weak object labels are
    /// usually things barely in frame (a fork on a far-away table), so objects need more
    /// confidence than the whole scene. Thresholds were tuned on the user's own edits.
    static func minimumConfidence(for label: String) -> Float {
        let k = key(label)
        // Scene labels can't be "too small to matter": the high-precision filter is enough.
        if sceneLabels.contains(k) { return 0 }
        // Distinctive subjects are rarely detected by accident.
        if distinctiveLabels.contains(k) { return 0.25 }
        // Generic clutter is in the frame of almost every photo; only tag it when it dominates.
        if clutterLabels.contains(k) { return 0.7 }
        return 0.5
    }

    /// Broader tags implied by `tags` (transitively) that the photo doesn't have yet,
    /// renamed by the user's merges. Tags the user deleted are never implied.
    static func implied(by tags: [String], merges: [String: String]) -> [String] {
        // Tags may carry the user's merged name ("Surf" for "surfing"), so also look up
        // every name that was merged into them.
        var sourcesByTarget: [String: [String]] = [:]
        for (source, target) in merges where !target.isEmpty {
            sourcesByTarget[target.lowercased(), default: []].append(key(source))
        }
        func lookupKeys(_ tag: String) -> [String] {
            let k = key(tag)
            var keys = [k] + (sourcesByTarget[k] ?? [])
            if let synonym = synonyms[k] { keys.append(synonym.lowercased()) }
            return keys
        }

        let present = Set(tags.map { $0.lowercased() })
        var result: [String] = []
        var seen = Set<String>()
        var queue = tags
        while let tag = queue.popLast() {
            for broader in lookupKeys(tag).flatMap({ implications[$0] ?? [] }) {
                guard let name = canonical(broader, merges: merges) else { continue }
                let lower = name.lowercased()
                guard seen.insert(lower).inserted else { continue }
                queue.append(name)
                if !present.contains(lower) { result.append(name) }
            }
        }
        return result
    }

    // MARK: Vocabulary

    /// Labels that never make useful tags: abstract parent categories Vision emits next
    /// to every specific label ("structure", "machine", "conveyance"), colors, materials,
    /// generic clothing and other words this library's owner kept deleting.
    static let ignored: Set<String> = [
        // Abstract parents and filler
        "structure", "conveyance", "portal", "machine", "material", "raw glass", "liquid", "object",
        "objects", "small objects", "thing", "item", "items", "decoration", "art", "artwork", "photo",
        "photograph", "image", "picture", "natural", "nature", "natural landscape", "land", "ground",
        "surface", "background", "foreground", "texture", "pattern", "shape", "scene", "view",
        "recreation", "leisure", "performance", "daytime", "day", "celestial body", "domicile",
        "container", "tool", "equipment", "sports equipment", "optical equipment", "engine vehicle",
        "wood natural", "wood processed", "wood", "metal", "plastic", "brick", "stone", "concrete",
        "textile", "fabric", "paper", "glass", "cord", "rope", "wires", "wire", "cable", "debris",
        "sediment", "mud", "dirt", "gravel", "crumbs", "sticks", "twigs", "buds", "spines", "cone",
        "construction", "residential", "ornate", "gradient", "blur", "light", "shadow", "dark",
        "streak", "reflections", "frame", "illustrations", "mammal", "ungulates", "canine", "feline",
        "vegetation", "rocky surface", "lake shore", "shore", "shoreline", "waterline", "horizon",
        "wall", "stairs", "steps", "table", "deck", "boat deck", "pointing", "mount", "frozen",
        "storm", "thunderstorm", "lightning", "parking lot", "high-rise", "interior shop",
        // Colors
        "black", "white", "gray", "grey", "red", "orange", "yellow", "green", "blue", "purple",
        "pink", "brown", "colors", "colorful",
        // Clothing (hats, sunglasses, eyeglasses and hoodies are kept)
        "clothing", "clothes", "apparel", "outfit", "footwear", "shoes", "shoe", "sneaker", "sneakers",
        "sandal", "boots", "jeans", "pants", "trousers", "shorts", "shirt", "shirts", "red shirts",
        "red top", "top", "blouse", "jacket", "coat", "scarf", "gloves", "glove", "sock", "socks",
        "dress", "skirt", "suit", "uniform", "belt", "backpack", "bag", "handbag",
        // Body parts
        "hand", "hands", "feet", "foot", "arm", "arms", "leg", "legs", "face", "hair", "head",
        // Table clutter that's never the point of a photo
        "utensil", "utensils", "fork", "knife", "spoon", "cutlery", "napkin",
    ]

    /// Different names for the same thing → the single tag name used in the library.
    static let synonyms: [String: String] = [
        // Sky and weather
        "sky": "Sky", "blue sky": "Sky", "clear sky": "Sky",
        "cloudy": "Cloudy", "cloud": "Cloudy", "clouds": "Cloudy", "cloudy sky": "Cloudy", "overcast": "Cloudy",
        "night sky": "Night sky", "starry sky": "Night sky", "stars": "Stars", "star": "Stars", "star trails": "Stars",
        "sunset sunrise": "Sunset / sunrise", "sunset": "Sunset / sunrise", "sunrise": "Sunset / sunrise",
        "golden hour": "Sunset / sunrise", "dusk": "Sunset / sunrise", "dawn": "Sunset / sunrise",
        "sunlight": "Sunlight", "sunshine": "Sunlight", "sun rays": "Sunlight", "sunbeams": "Sunlight",
        "outdoor": "Outdoor", "outdoors": "Outdoor", "outside": "Outdoor",
        "indoor": "Indoors", "indoors": "Indoors", "interior room": "Indoors", "interior": "Indoors", "inside": "Indoors",
        // Land
        "hill": "Hill", "hills": "Hill", "hillside": "Hill",
        "mountain": "Mountain", "mountains": "Mountain", "mountain range": "Mountain", "mountainous landscape": "Mountain",
        "mountainous area": "Mountain",
        "rock": "Rocks", "rocks": "Rocks", "rocky": "Rocks", "boulder": "Rocks", "boulders": "Rocks",
        "sand dune": "Sand dune", "sand dunes": "Sand dune", "dune": "Sand dune", "dunes": "Sand dune",
        "field": "Field", "grassy field": "Field", "open field": "Field", "meadow": "Field", "pasture": "Field",
        "rice field": "Field",
        "grass": "Grass", "lawn": "Grass",
        "countryside": "Rural", "rural area": "Rural", "farmland": "Rural", "farm": "Rural",
        // Water
        "water": "Water body", "water body": "Water body", "body of water": "Water body", "waterways": "Water body",
        "sea": "Ocean", "ocean": "Ocean", "seaside": "Ocean",
        "lake": "Lake", "mountain lake": "Lake", "river": "River", "stream": "Stream", "creek": "Stream",
        "wave": "Wave", "waves": "Wave", "surf wave": "Wave",
        "harbour": "Port", "harbor": "Port", "port": "Port", "marina": "Port", "shipyard": "Port",
        // Plants
        "tree": "Tree", "trees": "Tree", "oak tree": "Tree", "maple tree": "Tree", "eucalyptus tree": "Tree",
        "palm tree": "Palm tree", "palm trees": "Palm tree", "palm": "Palm tree",
        "evergreen": "Pine", "pine": "Pine", "pine tree": "Pine", "pine trees": "Pine", "conifer": "Pine",
        "plant": "Plant", "plants": "Plant", "decorative plant": "Plant",
        "foliage": "Foliage", "leaf": "Foliage", "leaves": "Foliage",
        "flowers": "Flowers", "flower": "Flowers", "blossom": "Flowers", "blossoms": "Flowers", "wildflowers": "Flowers",
        "bouquet": "Bouquet", "flower arrangement": "Bouquet", "forest": "Forest", "woods": "Forest", "woodland": "Forest",
        // Buildings and city
        "building": "Buildings", "buildings": "Buildings", "skyscraper": "Buildings", "skyscrapers": "Buildings",
        "house": "Houses", "houses": "Houses", "home": "Houses",
        "roof": "Roof", "rooftop": "Roof", "rooftops": "Roof",
        "window": "Window", "windows": "Window",
        "church": "Church", "religious site": "Church", "cathedral": "Church", "chapel": "Church", "belltower": "Tower",
        "street": "City street", "city street": "City street", "urban street": "City street",
        "road": "Road", "road other": "Road", "dirt road": "Road", "roadside": "Road",
        "highway": "Highway", "freeway": "Highway", "motorway": "Highway",
        "pole": "Pole", "lamppost": "Pole", "lamp post": "Pole", "lightpole": "Pole", "light pole": "Pole",
        "streetlight": "Pole", "street light": "Pole", "street lamp": "Pole", "utility pole": "Pole",
        "telephone pole": "Pole", "power pole": "Pole", "flagpole": "Pole",
        "crane construction": "Crane", "crane": "Crane", "cranes": "Crane",
        // People
        "people": "People", "person": "People", "persons": "People", "man": "People", "woman": "People",
        "men": "People", "women": "People", "human": "People", "crowd": "People",
        "adult": "Adult", "adults": "Adult",
        "child": "Child", "children": "Child", "kid": "Child", "kids": "Child", "teen": "Child", "boy": "Child", "girl": "Child",
        // Accessories that are kept
        "hat": "Hat", "cap": "Hat", "baseball hat": "Hat", "beanie": "Hat", "sunhat": "Hat", "cowboy hat": "Hat",
        "headgear": "Hat",
        "sunglasses": "Sunglasses", "glasses": "Eyeglasses", "eyeglasses": "Eyeglasses",
        "hoodie": "Hoodie", "hooded coat": "Hoodie", "hood": "Hoodie",
        "phone": "Mobile phone", "smartphone": "Mobile phone", "mobile phone": "Mobile phone", "cellphone": "Mobile phone",
        // Animals
        "animal": "Animals", "animals": "Animals", "wildlife": "Animals", "livestock": "Animals",
        "cattle": "Animals", "cow": "Animals", "cows": "Animals", "dog": "Animals", "dogs": "Animals", "donkey": "Animals",
        "bird": "Bird", "birds": "Bird", "seagull": "Bird", "gull": "Bird", "pigeon": "Bird",
        "horse": "Horse", "horses": "Horse", "pony": "Horse", "foal": "Horse",
        "cat": "Cat", "adult cat": "Cat", "cats": "Cat", "kitten": "Cat",
        "rodent": "Squirrel", "squirrel": "Squirrel",
        // Vehicles
        "vehicle": "Vehicle", "vehicles": "Vehicle",
        "car": "Car", "cars": "Car", "automobile": "Car", "sportscar": "Car", "police car": "Car",
        "boat": "Boat", "boats": "Boat", "ship": "Boat", "watercraft": "Boat", "boat on water": "Boat",
        "rowboat": "Boat", "sailboat": "Boat", "speedboat": "Boat", "cruise ship": "Boat", "houseboat": "Boat",
        "aircraft": "Aircraft", "airplane": "Airplane", "plane": "Airplane", "jet": "Airplane",
        "helicopter": "Helicopter",
        // Sport and activities
        "sport": "Sport", "sports": "Sport",
        "watersport": "Watersport", "water sport": "Watersport", "water sports": "Watersport", "watersports": "Watersport",
        "surf": "Surfing", "surfing": "Surfing", "surfer": "Surfing", "surfers": "Surfing",
        "surfboard": "Surfboard", "surfboards": "Surfboard", "bodyboard": "Surfboard", "boogie board": "Surfboard",
        "windsurf": "Windsurfing", "windsurfing": "Windsurfing", "windsurfer": "Windsurfing",
        "kitesurf": "Kitesurfing", "kitesurfing": "Kitesurfing", "kiteboarding": "Kitesurfing",
        "kayak": "Kayak", "kayaks": "Kayak", "kayaking": "Kayak", "canoe": "Kayak", "canoeing": "Kayak",
        "paddle": "Paddle", "oar": "Paddle", "paddles": "Paddle",
        "paddleboard": "Paddleboarding", "paddleboarding": "Paddleboarding", "stand up paddle": "Paddleboarding",
        "sailing": "Sailing", "swimming": "Swimming", "swim": "Swimming", "diving": "Diving", "snorkeling": "Snorkeling",
        "paraglider": "Paraglider", "paragliding": "Paraglider", "parachute": "Paraglider", "parasailing": "Paraglider",
        "skydiving": "Skydiving", "hang gliding": "Paraglider",
        "skiing": "Skiing", "ski": "Skiing", "snowboarding": "Snowboarding", "snowboard": "Snowboarding",
        "winter sport": "Winter sport",
        "hiking": "Hiking", "hike": "Hiking", "trekking": "Hiking",
        "fire": "Campfire", "flame": "Campfire", "flames": "Campfire", "bonfire": "Campfire", "campfire": "Campfire",
        "fireworks": "Fireworks", "pyrotechnics": "Fireworks", "sparkler": "Fireworks",
        "seat": "Chairs", "seats": "Chairs", "chair": "Chairs", "chairs": "Chairs",
    ]

    /// Tag → broader tags every photo with it should also have. Keys are lowercased
    /// library tag names; chains are followed (Surfing → Watersport → Sport).
    static let implications: [String: [String]] = [
        // Sport
        "surfing": ["Watersport"], "surfboard": ["Watersport"], "windsurfing": ["Watersport"],
        "kitesurfing": ["Watersport"], "kayak": ["Watersport"], "paddleboarding": ["Watersport"],
        "sailing": ["Watersport"], "swimming": ["Watersport"], "diving": ["Watersport"],
        "snorkeling": ["Watersport"], "waterpolo": ["Watersport"], "rowing": ["Watersport"],
        "wakeboarding": ["Watersport"], "water skiing": ["Watersport"],
        "watersport": ["Sport"], "winter sport": ["Sport"],
        "skiing": ["Winter sport"], "snowboarding": ["Winter sport"], "ice skating": ["Winter sport"],
        "paraglider": ["Sport"], "skydiving": ["Sport"], "rock climbing": ["Sport"], "climbing": ["Sport"],
        "hiking": ["Sport"], "cycling": ["Sport"], "running": ["Sport"], "soccer": ["Sport"],
        "football": ["Sport"], "basketball": ["Sport"], "volleyball": ["Sport"], "tennis": ["Sport"],
        "table tennis": ["Sport"], "golf": ["Sport"], "skateboarding": ["Sport"], "motorsport": ["Sport"],
        // People
        "adult": ["People"], "child": ["People"], "baby": ["People"], "couple": ["People"],
        "selfie": ["People"], "group selfie": ["People"], "group photo": ["People"],
        // Animals
        "bird": ["Animals"], "horse": ["Animals"], "cat": ["Animals"], "fox": ["Animals"],
        "squirrel": ["Animals"], "owl": ["Bird"], "camel": ["Animals"], "sheep": ["Animals"],
        "goat": ["Animals"], "deer": ["Animals"], "monkey": ["Animals"], "fish": ["Animals"],
        "llama": ["Animals"], "alpaca": ["Animals"], "capybara": ["Animals"], "lizard": ["Animals"],
        // Water
        "ocean": ["Water body"], "lake": ["Water body"], "river": ["Water body"], "stream": ["Water body"],
        "waterfall": ["Water body"], "pond": ["Water body"], "wave": ["Water body"],
        // Vehicles
        "car": ["Vehicle"], "truck": ["Vehicle"], "bus": ["Vehicle"], "train": ["Vehicle"],
        "motorcycle": ["Vehicle"], "bicycle": ["Vehicle"], "boat": ["Vehicle"],
        "airplane": ["Aircraft"], "helicopter": ["Aircraft"], "aircraft": ["Vehicle"],
        // Plants and landmarks
        "palm tree": ["Tree"], "pine": ["Tree"],
        "christ the redeemer": ["Statue"], "night sky": ["Sky"], "stars": ["Night sky"],
    ]

    /// Vision labels for subjects that are almost never detected by accident.
    private static let distinctiveLabels: Set<String> = [
        "sunglasses", "eyeglasses", "hat", "baseball hat", "sunhat", "cowboy hat", "hoodie",
        "surfboard", "surfing", "windsurfing", "watersport", "sport", "kayak", "canoe", "paraglider",
        "parasailing", "skiing", "snowboarding", "car", "automobile", "boat", "sailboat", "airplane",
        "helicopter", "train", "bicycle", "motorcycle", "horse", "bird", "cat", "dog", "fox", "camel",
        "owl", "squirrel", "animal", "statue", "tower", "church", "bridge", "volcano", "campfire",
        "fireworks", "bouquet", "moon", "stars", "rainbow", "lighthouse",
    ]

    /// Vision labels for generic things present in most photos.
    private static let clutterLabels: Set<String> = [
        "fence", "window", "pole", "lamppost", "utility pole", "flagpole", "sign", "street sign",
        "door", "chair", "seat", "bench", "sidewalk", "railing", "wall", "branch", "shrub", "box",
        "bottle", "cup", "plate", "bowl", "tableware", "furniture", "cabinet", "ball", "book",
    ]

    /// Vision labels for the scene as a whole (setting, weather, land, water, people).
    private static let sceneLabels: Set<String> = [
        "outdoor", "interior room", "sky", "blue sky", "cloudy", "night sky", "sunset sunrise", "sun", "haze",
        "fog", "snow", "land", "hill", "mountain", "cliff", "rocks", "grass", "field", "rice field", "forest",
        "garden", "park", "farm", "agriculture", "vineyard", "wetland", "beach", "sand", "sand dune", "desert",
        "island", "ocean", "lake", "river", "water", "water body", "waterfall", "waterways", "shore",
        "cityscape", "city", "street", "road", "dirt road", "highway", "alley", "bridge", "plant", "foliage",
        "tree", "palm tree", "evergreen", "people", "adult", "child", "teen", "baby", "crowd", "auditorium",
        "theater", "stadium", "airport", "harbour", "volcano", "canyon", "glacier", "path", "trail",
    ]
}

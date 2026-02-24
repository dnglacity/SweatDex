AI Review Context: ApexOnDeck
1. Project Identity & Stack

    Framework: Flutter (Targeting: Android, iOS, Web)

    State Management: Native. Require assistance in setting up.

    Architecture: Prototype / Service-Based.

    Current Flow: Widgets communicate directly with supabase_flutter via StreamBuilder and FutureBuilder.

    Goal: Transitioning toward a Layered Architecture with separate Repository classes.

    Critical Dependencies: Unsure.

2. Business Logic & Goals

    Core Purpose: Roster manager for sports coaches.

    Target Audience: Coaches, athletes, and guardians.

    Key Features: 
    1. Real-time data syncing
    2. Unsure.

3. Review Priorities (See .json files as necessary)

    1. Security: Data handling and authentication.

    2. Scalability: How easily can new features be added?

    3. Performance: Widget rebuilds and memory leaks.

    4. Maintainability: Code readability and DRY principles.
    
4. Known Issues & "Don't Touch" Areas

    Known Bugs: 
    
    Issue 1:
    getTeams error: PostgrestException(message: {"code":"42P17","details":null,"hint":null,"message":"infinite
recursion detected in policy for relation \"team_members\""}, code: 500, details: , hint: null)

    Technical Debt: None.

5. Coding Standards

    Note an explain each element of the code or script.

6. Questions

    
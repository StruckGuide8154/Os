
import csv
import collections

# Using absolute path for the input file
csv_file = r'c:\Users\user\Downloads\2311eb.csv'
reasons_counter = collections.Counter()
reasons_status_counter = collections.Counter()

limit = 50000

print(f"Reading {csv_file} (first {limit} rows)...")

try:
    with open(csv_file, 'r', encoding='utf-8') as f:
        # Use csv without wrapper to be safer or detect delimiter?
        # Assuming comma delimiter as seen in view_file.
        # But wait, looking at the previous output, the fields were separated by commas.
        # However, some fields had quotes like "blacklist".
        


        csv.field_size_limit(1000000)
        reader = csv.DictReader(f)
        
        tag_counter = collections.Counter()
        

        target_tags = ['gambling', 'dating', 'adult', 'porn', 'sex', 'xxx', '18+', '16+']
        # Extended keywords for domain search
        domain_keywords = ['gambling', 'dating', 'adult', 'porn', 'sex', 'xxx', 'bet', 'casino', 'poker', 'escort']
        
        found_rows = []

        for i, row in enumerate(reader):
            if i >= 6500000: break
            
            # Check reasons (tags)
            r = row.get('reasons', '')
            domain = row.get('domain', row.get('matched_name', ''))
            ts = row.get('\ufefftimestamp', row.get('timestamp',''))
            
            matched = False
            
            if r:
                tags = [t.strip() for t in r.split(',')]
                for tag in tags:
                    tag_counter[tag] += 1
                    for target in target_tags:
                        if target in tag.lower():
                             found_rows.append((i+2, ts, domain, f"Tag: {tag}"))
                             matched = True
                             break
            
            # If not matched by tag, check domain text "yourself"
            if not matched and domain:
                d_lower = domain.lower()
                for kw in domain_keywords:
                    if kw in d_lower:
                        # Simple keyword matching, might have false positives (e.g. 'essex', 'sussex', 'bet' in 'alphabet')
                        # Refine: check for word boundaries or specific patterns?
                        # For now, simplistic check but maybe filter obvious false positives
                        if kw == 'sex' and ('essex' in d_lower or 'sussex' in d_lower): continue
                        if kw == 'bet' and ('alpha' in d_lower or 'beta' in d_lower or 'better' in d_lower or 'between' in d_lower): continue
                        
                        found_rows.append((i+2, ts, domain, f"Domain Keyword: {kw}"))
                        break

    print("\nAll Unique Tags found:")
    for t, count in tag_counter.most_common():
        print(f"'{t}': {count}")

    print("\nTarget Matches:")
    for row_num, ts, dom, tag in found_rows:
        print(f"Row {row_num}: {ts} - {dom} ({tag})")

except Exception as e:
    print(f"Error: {e}")

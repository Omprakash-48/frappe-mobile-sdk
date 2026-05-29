import os
import json
import re

def sanitize_filename(name):
    # Convert spaces to underscores and remove non-alphanumeric chars
    name = name.lower()
    name = re.sub(r'[^a-z0-9]+', '_', name)
    return name.strip('_')

def extract_doctypes(input_file, output_dir):
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
        print(f"Created directory: {output_dir}")

    count = 0
    with open(input_file, 'r') as f:
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) < 3:
                continue
            
            doctype_name = parts[1].strip()
            json_content = parts[2].strip()
            
            if not doctype_name or json_content == '{}':
                continue
            
            filename = sanitize_filename(doctype_name) + '.json'
            filepath = os.path.join(output_dir, filename)
            
            try:
                data = json.loads(json_content)
                with open(filepath, 'w') as out:
                    json.dump(data, out, indent=2)
                count += 1
            except json.JSONDecodeError:
                print(f"Error decoding JSON for doctype: {doctype_name}")

    print(f"Extracted {count} doctypes to {output_dir}")

if __name__ == "__main__":
    extract_doctypes('AllDoctypesDump.md', 'assets/doctypes')

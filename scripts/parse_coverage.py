import sys
import os

def parse_lcov(file_path):
    total_lines_found = 0
    total_lines_hit = 0
    files = {}

    if not os.path.exists(file_path):
        print(f"Error: {file_path} not found.")
        return

    current_file = None
    lines_found = 0
    lines_hit = 0

    with open(file_path, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('SF:'):
                current_file = line.split('SF:')[1]
            elif line.startswith('LF:'):
                lines_found = int(line.split(':')[1])
            elif line.startswith('LH:'):
                lines_hit = int(line.split(':')[1])
            elif line == 'end_of_record':
                if current_file:
                    files[current_file] = {
                        'found': lines_found,
                        'hit': lines_hit,
                        'percent': (lines_hit / lines_found * 100) if lines_found > 0 else 0
                    }
                    total_lines_found += lines_found
                    total_lines_hit += lines_hit
                current_file = None
                lines_found = 0
                lines_hit = 0

    print("-" * 80)
    print(f"{'File':<50} | {'Coverage':<10} | {'Lines'}")
    print("-" * 80)
    
    # Sort files by coverage (lowest first) to highlight what needs work
    sorted_files = sorted(files.items(), key=lambda x: x[1]['percent'])
    
    for file, stats in sorted_files:
        # Show only relative path from lib/
        rel_path = file.split('lib/')[-1] if 'lib/' in file else file
        print(f"{rel_path[:48]:<50} | {stats['percent']:>8.2f}% | {stats['hit']}/{stats['found']}")

    print("-" * 80)
    total_percent = (total_lines_hit / total_lines_found * 100) if total_lines_found > 0 else 0
    print(f"{'TOTAL':<50} | {total_percent:>8.2f}% | {total_lines_hit}/{total_lines_found}")
    print("-" * 80)

if __name__ == "__main__":
    path = 'coverage/lcov.info'
    if len(sys.argv) > 1:
        path = sys.argv[1]
    parse_lcov(path)

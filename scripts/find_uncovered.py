import sys

def find_uncovered_lines(lcov_path, target_file):
    with open(lcov_path, 'r') as f:
        in_target = False
        uncovered = []
        for line in f:
            line = line.strip()
            if line.startswith('SF:') and target_file in line:
                in_target = True
            elif line == 'end_of_record':
                in_target = False
            elif in_target and line.startswith('DA:'):
                # DA:<line_number>,<hit_count>
                parts = line.split(':')[1].split(',')
                line_num = int(parts[0])
                hits = int(parts[1])
                if hits == 0:
                    uncovered.append(line_num)
        return uncovered

if __name__ == "__main__":
    target = sys.argv[1]
    lcov = 'coverage/lcov.info'
    lines = find_uncovered_lines(lcov, target)
    print(f"Uncovered lines in {target}: {lines}")
